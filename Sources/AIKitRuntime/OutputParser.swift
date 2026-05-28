import Foundation
import AIKitCore
import AIKitCapability

/// What the model wants to happen next.
public enum ParsedOutput: Sendable, Hashable {
    case final(String)
    case toolCalls([ToolCall])
    case mixed(text: String, toolCalls: [ToolCall])
    case workflow(WorkflowSpec)
    case mixedWorkflow(text: String, workflow: WorkflowSpec)
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
    ///   text is recovered as a tool call. Lets models without native function
    ///   calling (common for local models) still drive tools.
    public static func parse(
        _ response: LLMResponse,
        allowToolCallFallback: Bool = false
    ) throws -> ParsedOutput {
        var text = ""
        var calls: [ToolCall] = []
        var workflow: WorkflowSpec?

        for block in response.content {
            switch block {
            case .text(let value):
                text += value
            case .reasoning:
                // Not part of the parsed intent; the Orchestrator surfaces it
                // separately as a reasoning event.
                continue
            case .image:
                continue
            case .audio(let audio):
                if let transcript = audio.transcript {
                    if !text.isEmpty { text += "\n" }
                    text += transcript
                }
            case .toolUse(let id, let name, let input):
                // A tool_use block whose input failed to decode upstream is
                // surfaced so the ErrorHandler can re-prompt.
                if let raw = Self.malformedToolInputRaw(in: input) {
                    throw ParserError.malformedToolInput(name: name, raw: raw)
                }
                if case .null = input {
                    throw ParserError.malformedToolInput(name: name, raw: "null")
                }
                calls.append(ToolCall(id: id, name: name, input: input))
            case .toolResult:
                continue
            }
        }

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        workflow = try Self.popWorkflowCall(from: &calls)

        if workflow == nil, !trimmed.isEmpty {
            if let recovered = try Self.recoverWorkflowSpec(in: trimmed) {
                workflow = recovered.spec
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

        if workflow == nil {
            workflow = try Self.popWorkflowCall(from: &calls)
        }

        if let workflow {
            guard calls.isEmpty else {
                throw ParserError.malformedWorkflow(
                    raw: "Workflow specs cannot be mixed with separate tool calls."
                )
            }
            return trimmed.isEmpty
                ? .workflow(workflow)
                : .mixedWorkflow(text: trimmed, workflow: workflow)
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

    // MARK: - Malformed native tool-call sentinel

    private static let malformedToolInputRawKey = "__aikit_malformed_tool_input_raw"

    private static func malformedToolInputRaw(in input: JSONValue) -> String? {
        guard case .object(let object) = input,
              object.count == 1,
              case .string(let raw)? = object[malformedToolInputRawKey]
        else { return nil }
        return raw
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
            guard body.contains("\"name\"") || body.contains("\"tool\"")
            else { continue }
            if let data = body.data(using: .utf8),
               let spec = try? JSONDecoder().decode(FencedSpec.self, from: data),
               let name = spec.resolvedName, !name.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Fenced tool-call fallback

    private struct FencedSpec: Decodable {
        let name: String?
        let tool: String?
        let input: JSONValue?
        let arguments: JSONValue?

        var resolvedName: String? { name ?? tool }
        var resolvedInput: JSONValue { input ?? arguments ?? .object([:]) }
    }

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

    private static func popWorkflowCall(from calls: inout [ToolCall]) throws -> WorkflowSpec? {
        guard let index = calls.firstIndex(where: { $0.name == WorkflowSpec.toolName })
        else { return nil }
        let call = calls.remove(at: index)
        do {
            return try WorkflowSpec.decodeToolCallInput(call.input)
        } catch {
            throw ParserError.malformedWorkflow(raw: Self.rawJSON(call.input))
        }
    }

    private static func decodeWorkflowCandidate(_ value: JSONValue) throws -> WorkflowSpec? {
        if case .object(let object) = value,
           let name = object["name"]?.stringValue ?? object["tool"]?.stringValue,
           name == WorkflowSpec.toolName,
           let input = object["input"] ?? object["arguments"] {
            do {
                return try WorkflowSpec.decodeToolCallInput(input)
            } catch {
                throw ParserError.malformedWorkflow(raw: Self.rawJSON(value))
            }
        }
        do {
            return try WorkflowSpec.decodeToolCallInput(value)
        } catch {
            return nil
        }
    }

    private static func recoverWorkflowSpec(
        in text: String
    ) throws -> (spec: WorkflowSpec, remainingText: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeWorkflow = Self.looksLikeWorkflowJSON(trimmed)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let value = try? JSONValue(data: data) {
            if let plan = try Self.decodeWorkflowCandidate(value) {
                return (plan, "")
            }
            if looksLikeWorkflow {
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
            guard let data = body.data(using: .utf8),
                  let value = try? JSONValue(data: data)
            else {
                throw ParserError.malformedWorkflow(raw: body)
            }
            if let plan = try Self.decodeWorkflowCandidate(value) {
                var remaining = text
                if let fullRange = Range(match.range, in: text) {
                    remaining.removeSubrange(fullRange)
                }
                return (plan, remaining)
            }
            throw ParserError.malformedWorkflow(raw: body)
        }
        return nil
    }

    private static func looksLikeWorkflowJSON(_ text: String) -> Bool {
        text.contains(WorkflowSpec.schemaVersion)
            || text.contains("\"\(WorkflowSpec.toolName)\"")
            || (text.contains("\"nodes\"")
                && text.contains("\"tool\"")
                && text.contains("\"input\"")
                && text.contains("\"depends_on\""))
    }

    private static func rawJSON(_ value: JSONValue) -> String {
        guard let data = try? value.data(),
              let text = String(data: data, encoding: .utf8)
        else { return "\(value)" }
        return text
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
        guard body.contains("\"name\"") || body.contains("\"tool\"") else {
            return nil
        }
        guard let data = body.data(using: .utf8),
              let spec = try? JSONDecoder().decode(FencedSpec.self, from: data),
              let name = spec.resolvedName, !name.isEmpty
        else {
            throw ParserError.malformedToolInput(name: "unknown", raw: body)
        }

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
        return (ToolCall(id: id, name: name, input: spec.resolvedInput), remaining)
    }
}
