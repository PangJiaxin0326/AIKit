import Foundation

/// A role in an LLM conversation.
public enum Role: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// A single block of content within a message or response.
public enum ContentBlock: Sendable, Codable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

/// A conversation message.
public struct Message: Sendable, Codable, Hashable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public init(role: Role, text: String) {
        self.init(role: role, content: [.text(text)])
    }

    /// Concatenated text of all `.text` blocks.
    public var plainText: String {
        content.compactMap(\.text).joined(separator: "\n")
    }
}

/// Token accounting for a single LLM call.
public struct TokenUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let zero = TokenUsage()
}

/// Why the model stopped generating.
public enum StopReason: Sendable, Codable, Hashable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case other(String)
}
