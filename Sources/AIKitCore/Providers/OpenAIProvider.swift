import Foundation

/// `LLMProvider` backed by the OpenAI Chat Completions API. Tool use is mapped
/// to function calling.
///
/// Works unmodified against any OpenAI-compatible backend (Ollama, llama.cpp,
/// vLLM, LM Studio). For no-auth local backends pass an empty `apiKey`: the
/// `Authorization` header is then omitted entirely. The base URL tolerates a
/// trailing `/v1` so `http://localhost:11434/v1` does not become
/// `/v1/v1/chat/completions`.
public struct OpenAIProvider: LLMProvider {
    public static let defaultBaseURL = URL(string: "https://api.openai.com")!
    public static let defaultModel = "gpt-4o"

    let configuration: LLMProviderConfiguration

    public var defaultModel: String { configuration.defaultModel }

    public init(configuration: LLMProviderConfiguration) {
        self.configuration = configuration
    }

    public init(
        apiKey: String,
        model: String = OpenAIProvider.defaultModel,
        baseURL: URL = OpenAIProvider.defaultBaseURL,
        timeout: TimeInterval? = nil,
        session: URLSession = .shared
    ) {
        self.init(configuration: .init(
            apiKey: apiKey,
            baseURL: baseURL,
            defaultModel: model,
            timeout: timeout,
            session: session
        ))
    }

    // MARK: - Non-streaming

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let urlRequest = try makeURLRequest(request, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await configuration.session.data(for: urlRequest)
        } catch {
            throw LLMError.from(transport: error)
        }
        try Self.validate(response, data: data)
        do {
            let wire = try JSONDecoder().decode(WireResponse.self, from: data)
            return try wire.toResponse(requestedAudioFormat: request.audioOutput?.format)
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.decodingFailed(String(describing: error))
        }
    }

    // MARK: - Streaming

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request, stream: true)
                    let (bytes, response) = try await configuration.session.bytes(for: urlRequest)
                    try Self.validate(response, data: Data())
                    var activeToolIDs: [Int: String] = [:]
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty else { continue }
                        if json == "[DONE]" { break }
                        guard let payload = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamEvent.self, from: payload)
                        else { continue }
                        for chunk in event.chunks(
                            activeToolIDs: &activeToolIDs,
                            requestedAudioFormat: request.audioOutput?.format
                        ) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.from(transport: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request construction

    /// Body keys owned by the wire encoder; `extraBody` may not override these.
    private static let reservedBodyKeys: Set<String> = [
        "model", "messages", "tools", "temperature", "max_tokens",
        "stream", "stream_options", "modalities", "audio",
    ]

    private func makeURLRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        let url = try configuration.baseURL.resolvingEndpoint(
            apiPrefix: "v1", endpoint: "chat/completions"
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            urlRequest.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        if let timeout = configuration.timeout {
            urlRequest.timeoutInterval = timeout
        }
        do {
            let wire = try WireRequest(request: request, model: request.model, stream: stream)
            urlRequest.httpBody = try mergedRequestBody(
                encoded: JSONEncoder().encode(wire),
                extraBody: request.extraBody,
                reservedKeys: Self.reservedBodyKeys
            )
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.encodingFailed(String(describing: error))
        }
        return urlRequest
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpStatus(code: http.statusCode, body: body)
        }
    }
}

// MARK: - Wire types

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?
    let temperature: Double?
    let max_tokens: Int?
    let modalities: [String]?
    let audio: WireAudioOutput?
    let stream: Bool
    let stream_options: StreamOptions?

    struct StreamOptions: Encodable {
        let include_usage: Bool
    }

    init(request: LLMRequest, model: String, stream: Bool) throws {
        self.model = model
        self.stream = stream
        self.stream_options = stream ? StreamOptions(include_usage: true) : nil
        self.temperature = request.temperature
        self.max_tokens = request.maxTokens
        if let audioOutput = request.audioOutput {
            self.modalities = ["text", "audio"]
            self.audio = try WireAudioOutput(audioOutput)
        } else {
            self.modalities = nil
            self.audio = nil
        }

        var messages: [WireMessage] = []
        if let system = request.system {
            messages.append(WireMessage(role: "system", content: .text(system)))
        }
        for message in request.messages {
            switch message.role {
            case .system:
                try Self.requireTextOnly(message, provider: "OpenAI system messages")
                messages.append(WireMessage(role: "system", content: .text(message.plainText)))
            case .user:
                messages.append(WireMessage(
                    role: "user",
                    content: try WireMessageContent(message: message)
                ))
            case .assistant:
                let toolCalls: [WireToolCall] = message.content.compactMap { block in
                    if case .toolUse(let id, let name, let input) = block {
                        let args = (try? input.data())
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return WireToolCall(
                            id: id,
                            function: .init(name: name, arguments: args)
                        )
                    }
                    return nil
                }
                let text = message.plainText
                let audioID = message.audio.first { $0.id?.isEmpty == false }?.id
                messages.append(WireMessage(
                    role: "assistant",
                    content: text.isEmpty ? nil : .text(text),
                    tool_calls: toolCalls.isEmpty ? nil : toolCalls,
                    audio: audioID.map(WireAssistantAudio.init)
                ))
            case .tool:
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, _) = block {
                        messages.append(WireMessage(
                            role: "tool",
                            content: .text(content),
                            tool_call_id: toolUseID
                        ))
                    }
                }
            }
        }
        self.messages = messages
        self.tools = request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
    }

    private static func requireTextOnly(_ message: Message, provider: String) throws {
        guard message.images.isEmpty, message.audio.isEmpty else {
            throw LLMError.unsupported("\(provider) support text only.")
        }
    }
}

private struct WireAudioOutput: Encodable {
    let voice: String
    let format: String

    init(_ options: AudioOutputOptions) throws {
        switch options.format {
        case .wav, .mp3, .flac, .opus, .pcm16:
            self.format = options.format.rawValue
        case .aac:
            throw LLMError.unsupported("OpenAI audio output supports wav, mp3, flac, opus, or pcm16.")
        }
        self.voice = options.voice
    }
}

private struct WireAssistantAudio: Encodable {
    let id: String
}

private enum WireMessageContent: Encodable {
    case text(String)
    case parts([WireContentPart])

    init(message: Message) throws {
        var parts: [WireContentPart] = []
        var hasMedia = false
        for block in message.content {
            switch block {
            case .text(let text):
                parts.append(.text(text))
            case .reasoning:
                continue
            case .image(let image):
                parts.append(.image(image))
                hasMedia = true
            case .audio(let audio):
                parts.append(.audio(audio))
                hasMedia = true
            case .toolUse, .toolResult:
                continue
            }
        }
        if hasMedia {
            self = .parts(parts)
        } else {
            self = .text(message.plainText)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .parts(let parts):
            var container = encoder.singleValueContainer()
            try container.encode(parts)
        }
    }
}

private enum WireContentPart: Encodable {
    case text(String)
    case image(ImageContent)
    case audio(AudioContent)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case inputAudio = "input_audio"
    }

    enum ImageURLKeys: String, CodingKey {
        case url, detail
    }

    enum InputAudioKeys: String, CodingKey {
        case data, format
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image_url", forKey: .type)
            var imageContainer = container.nestedContainer(
                keyedBy: ImageURLKeys.self, forKey: .imageURL
            )
            try imageContainer.encode(openAIImageURL(image.source), forKey: .url)
            if let detail = image.detail {
                try imageContainer.encode(detail.rawValue, forKey: .detail)
            }
        case .audio(let audio):
            try container.encode("input_audio", forKey: .type)
            var audioContainer = container.nestedContainer(
                keyedBy: InputAudioKeys.self, forKey: .inputAudio
            )
            let payload = try openAIInputAudio(audio)
            try audioContainer.encode(payload.data, forKey: .data)
            try audioContainer.encode(payload.format, forKey: .format)
        }
    }
}

private struct WireMessage: Encodable {
    let role: String
    var content: WireMessageContent?
    var tool_calls: [WireToolCall]?
    var tool_call_id: String?
    var audio: WireAssistantAudio?

    init(
        role: String,
        content: WireMessageContent? = nil,
        tool_calls: [WireToolCall]? = nil,
        tool_call_id: String? = nil,
        audio: WireAssistantAudio? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.audio = audio
    }
}

private struct WireToolCall: Encodable, Decodable {
    struct Function: Encodable, Decodable {
        let name: String?
        let arguments: String?
    }
    var id: String?
    let type: String?
    let function: Function
    var index: Int?

    init(id: String, function: Function) {
        self.id = id
        self.type = "function"
        self.function = function
    }
}

private let malformedToolInputRawKey = "__aikit_malformed_tool_input_raw"

private func malformedToolInput(raw: String) -> JSONValue {
    .object([malformedToolInputRawKey: .string(raw)])
}

private func openAIImageURL(_ source: MediaSource) -> String {
    switch source {
    case .url(let url):
        return url.absoluteString
    case .data(let mimeType, let data):
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

private func openAIInputAudio(_ audio: AudioContent) throws -> (data: String, format: String) {
    guard case .data(let mimeType, let data) = audio.source else {
        throw LLMError.unsupported("OpenAI input audio requires base64 audio data, not a remote URL.")
    }
    let format = try openAIInputAudioFormat(audio.format, mimeType: mimeType)
    return (data.base64EncodedString(), format)
}

private func openAIInputAudioFormat(
    _ format: AudioFormat?,
    mimeType: String
) throws -> String {
    if let format {
        switch format {
        case .wav, .mp3:
            return format.rawValue
        case .flac, .opus, .aac, .pcm16:
            throw LLMError.unsupported("OpenAI input audio supports wav or mp3.")
        }
    }
    switch mimeType.lowercased() {
    case "audio/wav", "audio/x-wav", "audio/wave":
        return "wav"
    case "audio/mpeg", "audio/mp3":
        return "mp3"
    default:
        throw LLMError.unsupported("OpenAI input audio requires wav or mp3 data.")
    }
}

private struct WireTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }
    let type = "function"
    let function: Function

    init(_ descriptor: ToolDescriptor) {
        self.function = .init(
            name: descriptor.name,
            description: descriptor.description,
            parameters: descriptor.inputSchema
        )
    }
}

private struct WireResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable {
            let content: String?
            // Reasoning models behind the Chat Completions shim (DeepSeek-R1,
            // QwQ, Ollama's `/v1`) put chain-of-thought here.
            let reasoning_content: String?
            let audio: Audio?
            let tool_calls: [WireToolCall]?
        }
        let message: Msg
        let finish_reason: String?
    }
    struct Audio: Decodable {
        let id: String?
        let expires_at: Int?
        let data: String?
        let transcript: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
    let choices: [Choice]
    let usage: Usage?

    func toResponse(requestedAudioFormat: AudioFormat?) throws -> LLMResponse {
        guard let choice = choices.first else {
            throw LLMError.decodingFailed("no choices in response")
        }
        var blocks: [ContentBlock] = []
        if let reasoning = choice.message.reasoning_content, !reasoning.isEmpty {
            blocks.append(.reasoning(reasoning))
        }
        if let text = choice.message.content, !text.isEmpty {
            blocks.append(.text(text))
        }
        if let audio = choice.message.audio {
            if let encoded = audio.data, !encoded.isEmpty {
                guard let data = Data(base64Encoded: encoded) else {
                    throw LLMError.decodingFailed("invalid OpenAI audio data")
                }
                let expiresAt = audio.expires_at.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                blocks.append(.audio(AudioContent(
                    data: data,
                    mimeType: requestedAudioFormat?.mimeType ?? "application/octet-stream",
                    format: requestedAudioFormat,
                    transcript: audio.transcript,
                    id: audio.id,
                    expiresAt: expiresAt
                )))
            } else if let transcript = audio.transcript, !transcript.isEmpty {
                blocks.append(.text(transcript))
            }
        }
        for call in choice.message.tool_calls ?? [] {
            let input: JSONValue
            if let args = call.function.arguments {
                if args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    input = .object([:])
                } else if let data = args.data(using: .utf8),
                          let value = try? JSONValue(data: data) {
                    input = value
                } else {
                    input = malformedToolInput(raw: args)
                }
            } else {
                input = .object([:])
            }
            blocks.append(.toolUse(
                id: call.id ?? "",
                name: call.function.name ?? "",
                input: input
            ))
        }
        let stop: StopReason
        switch choice.finish_reason {
        case "stop": stop = .endTurn
        case "tool_calls": stop = .toolUse
        case "length": stop = .maxTokens
        case let other?: stop = .other(other)
        case nil: stop = .endTurn
        }
        return LLMResponse(
            content: blocks,
            stopReason: stop,
            usage: TokenUsage(
                inputTokens: usage?.prompt_tokens ?? 0,
                outputTokens: usage?.completion_tokens ?? 0
            )
        )
    }
}

private struct StreamEvent: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct Audio: Decodable {
                let data: String?
                let transcript: String?
            }
            let content: String?
            let reasoning_content: String?
            let audio: Audio?
            let tool_calls: [WireToolCall]?
        }
        let delta: Delta
        let finish_reason: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
    // The trailing usage chunk (requested via `stream_options.include_usage`)
    // carries an empty `choices` array, so it must default to empty.
    let choices: [Choice]
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case choices, usage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        self.usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
    }

    func chunks(
        activeToolIDs: inout [Int: String],
        requestedAudioFormat: AudioFormat?
    ) -> [LLMResponseChunk] {
        var result: [LLMResponseChunk] = []
        for choice in choices {
            if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                result.append(.reasoningDelta(reasoning))
            }
            if let text = choice.delta.content, !text.isEmpty {
                result.append(.textDelta(text))
            }
            if let audio = choice.delta.audio {
                if let encoded = audio.data,
                   let data = Data(base64Encoded: encoded) {
                    result.append(.audio(AudioContent(
                        data: data,
                        mimeType: requestedAudioFormat?.mimeType ?? "application/octet-stream",
                        format: requestedAudioFormat,
                        transcript: audio.transcript
                    )))
                } else if let transcript = audio.transcript, !transcript.isEmpty {
                    result.append(.textDelta(transcript))
                }
            }
            for call in choice.delta.tool_calls ?? [] {
                let index = call.index ?? 0
                if let id = call.id, activeToolIDs[index] == nil {
                    activeToolIDs[index] = id
                    result.append(.toolUseStart(
                        id: id,
                        name: call.function.name ?? ""
                    ))
                }
                if let args = call.function.arguments, !args.isEmpty {
                    result.append(.toolUseInputDelta(
                        id: activeToolIDs[index] ?? String(index),
                        json: args
                    ))
                }
            }
            switch choice.finish_reason {
            case "stop": result.append(.stop(.endTurn))
            case "tool_calls": result.append(.stop(.toolUse))
            case "length": result.append(.stop(.maxTokens))
            case let other?: result.append(.stop(.other(other)))
            case nil: break
            }
        }
        if let usage {
            result.append(.usage(TokenUsage(
                inputTokens: usage.prompt_tokens ?? 0,
                outputTokens: usage.completion_tokens ?? 0
            )))
        }
        return result
    }
}
