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
    /// Model-emitted chain-of-thought / reasoning (Ollama `thinking`, OpenAI
    /// `reasoning_content`, Anthropic extended-thinking blocks). Surfaced so a
    /// host can show or log it; never re-sent to a provider (the Orchestrator
    /// rebuilds assistant turns from final text + tool calls only).
    case reasoning(String)
    case image(ImageContent)
    case audio(AudioContent)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var reasoning: String? {
        if case .reasoning(let value) = self { return value }
        return nil
    }

    public var image: ImageContent? {
        if case .image(let value) = self { return value }
        return nil
    }

    public var audio: AudioContent? {
        if case .audio(let value) = self { return value }
        return nil
    }
}

/// A binary or remote media asset attached to a message.
public enum MediaSource: Sendable, Codable, Hashable {
    case url(URL)
    case data(mimeType: String, data: Data)

    public init(url: URL) {
        self = .url(url)
    }

    public init(data: Data, mimeType: String) {
        self = .data(mimeType: mimeType, data: data)
    }

    public var url: URL? {
        if case .url(let value) = self { return value }
        return nil
    }

    public var data: (mimeType: String, data: Data)? {
        if case .data(let mimeType, let data) = self {
            return (mimeType, data)
        }
        return nil
    }

    public var description: String {
        switch self {
        case .url(let url):
            return url.absoluteString
        case .data(let mimeType, let data):
            return "\(mimeType), \(data.count) bytes"
        }
    }
}

/// Image input for vision-capable multimodal models.
public struct ImageContent: Sendable, Codable, Hashable {
    public enum Detail: String, Sendable, Codable, Hashable {
        case auto
        case low
        case high
    }

    public var source: MediaSource
    public var detail: Detail?

    public init(source: MediaSource, detail: Detail? = nil) {
        self.source = source
        self.detail = detail
    }

    public init(data: Data, mimeType: String, detail: Detail? = nil) {
        self.init(source: .data(mimeType: mimeType, data: data), detail: detail)
    }

    public init(url: URL, detail: Detail? = nil) {
        self.init(source: .url(url), detail: detail)
    }
}

/// Audio input or generated voice output for audio-capable models.
public struct AudioContent: Sendable, Codable, Hashable {
    public var source: MediaSource
    public var format: AudioFormat?
    public var transcript: String?
    public var id: String?
    public var expiresAt: Date?

    public init(
        source: MediaSource,
        format: AudioFormat? = nil,
        transcript: String? = nil,
        id: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.source = source
        self.format = format
        self.transcript = transcript
        self.id = id
        self.expiresAt = expiresAt
    }

    public init(
        data: Data,
        mimeType: String,
        format: AudioFormat? = nil,
        transcript: String? = nil,
        id: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.init(
            source: .data(mimeType: mimeType, data: data),
            format: format,
            transcript: transcript,
            id: id,
            expiresAt: expiresAt
        )
    }

    public init(
        url: URL,
        format: AudioFormat? = nil,
        transcript: String? = nil,
        id: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.init(
            source: .url(url),
            format: format,
            transcript: transcript,
            id: id,
            expiresAt: expiresAt
        )
    }
}

public enum AudioFormat: String, Sendable, Codable, Hashable {
    case wav
    case mp3
    case flac
    case opus
    case aac
    case pcm16

    public var mimeType: String {
        switch self {
        case .wav: return "audio/wav"
        case .mp3: return "audio/mpeg"
        case .flac: return "audio/flac"
        case .opus: return "audio/opus"
        case .aac: return "audio/aac"
        case .pcm16: return "audio/pcm"
        }
    }
}

/// Voice and format requested from providers that can synthesize audio.
public struct AudioOutputOptions: Sendable, Codable, Hashable {
    public var voice: String
    public var format: AudioFormat

    public init(voice: String, format: AudioFormat) {
        self.voice = voice
        self.format = format
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

    public var images: [ImageContent] {
        content.compactMap(\.image)
    }

    public var audio: [AudioContent] {
        content.compactMap(\.audio)
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
