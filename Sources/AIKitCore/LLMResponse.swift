import Foundation
import FoundationModels
import AIToolKit

/// A complete, non-streamed response from an LLM provider.
public struct LLMResponse: Sendable, Codable, Hashable {
    public var content: [ContentBlock]
    public var stopReason: StopReason
    public var usage: TokenUsage

    public init(
        content: [ContentBlock],
        stopReason: StopReason,
        usage: TokenUsage = .zero
    ) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    /// Concatenated text of all `.text` blocks.
    public var text: String {
        content.compactMap(\.text).joined()
    }

    /// Concatenated text of all `.reasoning` blocks (empty when the model or
    /// provider emitted none).
    public var reasoning: String {
        content.compactMap(\.reasoning).joined()
    }

    /// All `.toolUse` blocks in order.
    public var toolUses: [(id: String, name: String, arguments: GeneratedContent)] {
        content.compactMap { block in
            if case .toolUse(let id, let name, let arguments) = block {
                return (id, name, arguments)
            }
            return nil
        }
    }

    public var images: [ImageContent] {
        content.compactMap(\.image)
    }
}

/// An incremental chunk emitted by a streaming completion.
public enum LLMResponseChunk: Sendable, Hashable {
    case textDelta(String)
    /// An incremental chunk of model reasoning / chain-of-thought.
    case reasoningDelta(String)
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(id: String, json: String)
    case toolUseStop(id: String)
    case stop(StopReason)
    case usage(TokenUsage)
}
