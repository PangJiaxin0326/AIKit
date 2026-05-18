import Foundation

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
    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            if case .toolUse(let id, let name, let input) = block {
                return (id, name, input)
            }
            return nil
        }
    }

    public var images: [ImageContent] {
        content.compactMap(\.image)
    }

    public var audio: [AudioContent] {
        content.compactMap(\.audio)
    }

    public var audioTranscripts: [String] {
        audio.compactMap(\.transcript)
    }
}

/// An incremental chunk emitted by a streaming completion.
public enum LLMResponseChunk: Sendable, Hashable {
    case textDelta(String)
    /// An incremental chunk of model reasoning / chain-of-thought.
    case reasoningDelta(String)
    /// A complete generated audio block. Providers that stream base64 audio
    /// incrementally may coalesce it before emitting this chunk.
    case audio(AudioContent)
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(id: String, json: String)
    case toolUseStop(id: String)
    case stop(StopReason)
    case usage(TokenUsage)
}
