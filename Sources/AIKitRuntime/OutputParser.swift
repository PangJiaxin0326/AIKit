import Foundation
import AIKitCore
import AIKitCapability

/// What the model wants to happen next.
public enum ParsedOutput: Sendable, Hashable {
    case final(String)
    case toolCalls([ToolCall])
    case mixed(text: String, toolCalls: [ToolCall])
}

/// Converts an `LLMResponse` into app-aware intents.
public enum OutputParser {
    public enum ParserError: Error, Sendable, Hashable {
        case malformedToolInput(name: String, raw: String)
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

        for block in response.content {
            switch block {
            case .text(let value):
                text += value
            case .toolUse(let id, let name, let input):
                // A tool_use block whose input failed to decode upstream is
                // surfaced so the ErrorHandler can re-prompt.
                if case .null = input {
                    throw ParserError.malformedToolInput(name: name, raw: "null")
                }
                calls.append(ToolCall(id: id, name: name, input: input))
            case .toolResult:
                continue
            }
        }

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if allowToolCallFallback, calls.isEmpty, !trimmed.isEmpty {
            if let recovered = try Self.recoverFencedToolCall(in: trimmed) {
                calls.append(recovered.call)
                trimmed = recovered.remainingText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
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
        return (ToolCall(name: name, input: spec.resolvedInput), remaining)
    }
}
