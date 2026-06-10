import Foundation
import FoundationModels
import AIToolKit
import AIKitCore
import AIKitCapability

/// What the model wants to happen next. A workflow plan arrives as an
/// ordinary tool call named `WorkflowSpec.toolName`; the orchestrator
/// dispatches it to the unified `WorkflowTool`, which owns validation and
/// returns structured statuses the model can fix in the loop.
public enum ParsedOutput: Sendable, Equatable {
    case final(String)
    case toolCalls([ToolCall])
    case mixed(text: String, toolCalls: [ToolCall])
}

/// Converts an `LLMResponse` into app-aware intents.
public enum OutputParser {
    public enum ParserError: Error, Sendable, Hashable {
        case malformedToolInput(name: String, raw: String)
        case malformedWorkflow(raw: String)
        case empty
    }

    /// - Parameter allowToolCallFallback: when true and the response carries no
    ///   native `tool_use` blocks, a fenced ```tool JSON block embedded in the
    ///   text is recovered as a tool call. Lets text-only provider paths still
    ///   drive tools.
    public static func parse(
        _ response: LLMResponse,
        allowToolCallFallback: Bool = false
    ) throws -> ParsedOutput {
        var textParts: [String] = []
        var calls: [ToolCall] = []

        for block in response.content {
            switch block {
            case .text(let value):
                textParts.append(value)
            case .reasoning:
                // Not part of the parsed intent; the Orchestrator surfaces it
                // separately as a reasoning event.
                continue
            case .image:
                continue
            case .audio(let audio):
                if let transcript = audio.transcript {
                    if !textParts.isEmpty { textParts.append("\n") }
                    textParts.append(transcript)
                }
            case .toolUse(let id, let name, let arguments):
                // A tool_use block whose input failed to decode upstream is
                // surfaced so the ErrorHandler can re-prompt.
                if let raw = AIKitMalformedToolInput.raw(in: arguments) {
                    throw ParserError.malformedToolInput(name: name, raw: raw)
                }
                if case .null = arguments.kind {
                    throw ParserError.malformedToolInput(name: name, raw: "null")
                }
                calls.append(ToolCall(id: id, name: name, arguments: arguments))
            case .toolResult:
                continue
            }
        }

        var trimmed = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        // Text-only provider paths emit the workflow plan as bare or fenced
        // JSON; recover it as a workflow_run call so dispatch is uniform.
        if !calls.contains(where: { $0.name == WorkflowSpec.toolName }), !trimmed.isEmpty {
            if let recovered = try Self.recoverWorkflowCall(in: trimmed) {
                calls.append(recovered.call)
                trimmed = recovered.remainingText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if allowToolCallFallback, calls.isEmpty, !trimmed.isEmpty {
            if let recovered = try Self.recoverFencedToolCall(in: trimmed) {
                calls.append(recovered.call)
                trimmed = recovered.remainingText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if calls.contains(where: { $0.name == WorkflowSpec.toolName }), calls.count > 1 {
            throw ParserError.malformedWorkflow(
                raw: "Workflow runs cannot be mixed with separate tool calls."
            )
        }

        switch (trimmed.isEmpty, calls.isEmpty) {
        case (true, true):
            throw ParserError.empty
        case (false, true):
            return .final(trimmed)
        case (true, false):
            return .toolCalls(calls)
        case (false, false):
            return .mixed(text: trimmed, toolCalls: calls)
        }
    }

    // MARK: - Near-miss diagnostic

    // Any fenced block plus its (possibly empty) info string. Used only to
    // *detect* a mis-tagged tool call for a diagnostic — never to recover one,
    // since acting on bare / ```json fences would derail legitimate answers
    // that merely contain fenced JSON.
    private static let nearMissRegex = try? NSRegularExpression(
        pattern: "```[ \\t]*([A-Za-z0-9_+.\\-]*)[ \\t]*\\r?\\n(.*?)```",
        options: [.dotMatchesLineSeparators]
    )

    /// `true` when the text holds a fenced block that decodes as a tool call
    /// but is *not* tagged ```` ```tool ```` (commonly ```` ```json ````). The
    /// Orchestrator surfaces this as a warning when the fallback is active and
    /// nothing was recovered, so a near-miss isn't silently delivered as the
    /// final answer with no signal.
    public static func nearMissFencedToolBlock(in text: String) -> Bool {
        guard let regex = nearMissRegex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let tagRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text)
            else { continue }
            if text[tagRange].lowercased() == "tool" { continue }
            let body = String(text[bodyRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.contains("\"name\"")
            else { continue }
            if let value = try? GeneratedContent(json: body),
               let name = Self.toolName(in: value), !name.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Fenced tool-call fallback

    // Requires the explicit `tool` tag (the convention the prompt instructs).
    // Matching bare ``` / ```json blocks would derail legitimate answers that
    // happen to contain fenced JSON.
    private static let fenceRegex = try? NSRegularExpression(
        pattern: "```[ \\t]*tool[ \\t]*\\r?\\n(.*?)```",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    private static let workflowFenceRegex = try? NSRegularExpression(
        pattern: "```[ \\t]*(workflow|json|tool)[ \\t]*\\r?\\n(.*?)```",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    /// Recovers a workflow plan the model emitted as text — the whole reply as
    /// one bare JSON object, or a fenced block — as a `workflow_run` tool
    /// call. The plan is NOT validated here: `WorkflowTool` owns that and
    /// answers a malformed plan with a structured `invalid_plan` output the
    /// model can correct. Only JSON that *looks* like a workflow but does not
    /// parse at all is a hard error, so the ErrorHandler can re-prompt.
    private static func recoverWorkflowCall(
        in text: String
    ) throws -> (call: ToolCall, remainingText: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            if let value = try? GeneratedContent(json: trimmed) {
                if let arguments = Self.workflowArguments(in: value) {
                    return (Self.workflowCall(arguments), "")
                }
            } else if Self.looksLikeWorkflowJSON(trimmed) {
                throw ParserError.malformedWorkflow(raw: trimmed)
            }
        }

        guard let regex = workflowFenceRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let bodyRange = Range(match.range(at: 2), in: text)
            else { continue }
            let body = String(text[bodyRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.looksLikeWorkflowJSON(body)
            else { continue }
            guard let value = try? GeneratedContent(json: body)
            else {
                throw ParserError.malformedWorkflow(raw: body)
            }
            if let arguments = Self.workflowArguments(in: value) {
                var remaining = text
                if let fullRange = Range(match.range, in: text) {
                    remaining.removeSubrange(fullRange)
                }
                return (Self.workflowCall(arguments), remaining)
            }
            throw ParserError.malformedWorkflow(raw: body)
        }
        return nil
    }

    /// The workflow-call arguments inside `value`: either the
    /// `{"name":"workflow_run","arguments":{…}}` envelope, or a bare plan
    /// object whose `nodes` is an array of node objects naming a `tool`.
    private static func workflowArguments(in value: GeneratedContent) -> GeneratedContent? {
        guard let object = value.objectValue else { return nil }
        if object["name"]?.stringValue == WorkflowSpec.toolName,
           let input = object["arguments"] {
            return input
        }
        if let nodes = object["nodes"]?.arrayValue,
           !nodes.isEmpty,
           nodes.allSatisfy({ $0.objectValue?["tool"]?.stringValue != nil }) {
            return value
        }
        return nil
    }

    private static func workflowCall(_ arguments: GeneratedContent) -> ToolCall {
        ToolCall(name: WorkflowSpec.toolName, arguments: arguments)
    }

    private static func looksLikeWorkflowJSON(_ text: String) -> Bool {
        text.contains(WorkflowSpec.schemaVersion)
            || text.contains("\"\(WorkflowSpec.toolName)\"")
            || (text.contains("\"nodes\"")
                && text.contains("\"tool\"")
                && text.contains("\"input\""))
    }

    /// Looks for a fenced ```tool block holding a single JSON object describing
    /// a tool call. A block that is present but unparseable is a hard error so
    /// the ErrorHandler can re-prompt for valid JSON.
    private static func recoverFencedToolCall(
        in text: String
    ) throws -> (call: ToolCall, remainingText: String)? {
        guard let regex = fenceRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let bodyRange = Range(match.range(at: 1), in: text)
        else { return nil }

        let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Only treat the block as a tool call if it actually names one.
        guard body.contains("\"name\"") else {
            return nil
        }
        guard let value = try? GeneratedContent(json: body),
              let name = Self.toolName(in: value), !name.isEmpty
        else {
            throw ParserError.malformedToolInput(name: "unknown", raw: body)
        }
        let arguments = Self.toolArguments(in: value)

        var remaining = text
        if let fullRange = Range(match.range, in: text) {
            remaining.removeSubrange(fullRange)
        }
        // Synthesize a stable id. The model emitted raw JSON with no native
        // tool-use id, but the Orchestrator needs one so the assistant turn
        // it records carries a real `tool_use` block whose id the following
        // `tool_result` can reference. Without it, wire encoders emit a
        // `tool`/`tool_calls`-less message pair that backends reject.
        let id = "fallback-\(UUID().uuidString)"
        return (ToolCall(id: id, name: name, arguments: arguments), remaining)
    }

    private static func toolName(in value: GeneratedContent) -> String? {
        value.objectValue?["name"]?.stringValue
    }

    private static func toolArguments(in value: GeneratedContent) -> GeneratedContent {
        value.objectValue?["arguments"] ?? .object([:])
    }
}
