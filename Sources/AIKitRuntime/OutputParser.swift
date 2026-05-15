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

    public static func parse(_ response: LLMResponse) throws -> ParsedOutput {
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

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
