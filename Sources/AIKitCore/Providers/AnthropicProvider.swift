import Foundation

/// `LLMProvider` backed by the Anthropic Messages API.
public struct AnthropicProvider: LLMProvider {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let defaultModel = "claude-opus-4-7"
    public static let apiVersion = "2023-06-01"

    let configuration: LLMProviderConfiguration

    public var defaultModel: String { configuration.defaultModel }

    public init(configuration: LLMProviderConfiguration) {
        self.configuration = configuration
    }

    public init(
        apiKey: String,
        model: String = AnthropicProvider.defaultModel,
        baseURL: URL = AnthropicProvider.defaultBaseURL,
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
            return wire.toResponse()
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
                        guard !json.isEmpty, json != "[DONE]" else { continue }
                        guard let payload = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamEvent.self, from: payload)
                        else { continue }
                        for chunk in event.chunks(activeToolIDs: &activeToolIDs) {
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
        "model", "system", "messages", "tools", "temperature",
        "max_tokens", "stream",
    ]

    private func makeURLRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        let url = try configuration.baseURL.resolvingEndpoint(
            apiPrefix: "v1", endpoint: "messages"
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        }
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let timeout = configuration.timeout {
            urlRequest.timeoutInterval = timeout
        }

        do {
            let body = try WireRequest(request: request, model: request.model, stream: stream)
            urlRequest.httpBody = try mergedRequestBody(
                encoded: JSONEncoder().encode(body),
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
    let system: String?
    let messages: [WireMessage]
    let tools: [WireTool]?
    let temperature: Double?
    let max_tokens: Int
    let stream: Bool

    init(request: LLMRequest, model: String, stream: Bool) throws {
        if request.audioOutput != nil {
            throw LLMError.unsupported(
                "AnthropicProvider does not support generated audio output."
            )
        }
        self.model = model
        self.stream = stream
        self.temperature = request.temperature
        self.max_tokens = request.maxTokens ?? 4096

        var systemParts: [String] = []
        if let system = request.system { systemParts.append(system) }
        var wireMessages: [WireMessage] = []
        for message in request.messages {
            // Reasoning blocks are never sent back to a provider; the
            // Orchestrator already strips them when rebuilding assistant turns,
            // but filter defensively so a hand-built message can't leak CoT.
            let blocks = message.content.filter {
                if case .reasoning = $0 { return false }
                return true
            }
            switch message.role {
            case .system:
                systemParts.append(message.plainText)
            case .user, .assistant:
                wireMessages.append(WireMessage(
                    role: message.role == .assistant ? "assistant" : "user",
                    content: blocks.map(WireContent.init)
                ))
            case .tool:
                wireMessages.append(WireMessage(
                    role: "user",
                    content: blocks.map(WireContent.init)
                ))
            }
        }
        self.system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        self.messages = wireMessages
        self.tools = request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
    }
}

private struct WireMessage: Encodable {
    let role: String
    let content: [WireContent]
}

private struct WireContent: Encodable {
    let block: ContentBlock
    init(_ block: ContentBlock) { self.block = block }

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
        case source
    }

    enum SourceKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
        case url
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch block {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoning(let text):
            // Unreachable: reasoning is filtered out before wire mapping.
            // Encoded as text so the switch stays total and a future caller
            // can't silently drop content.
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            switch image.source {
            case .url(let url):
                try source.encode("url", forKey: .type)
                try source.encode(url.absoluteString, forKey: .url)
            case .data(let mimeType, let data):
                try source.encode("base64", forKey: .type)
                try source.encode(mimeType, forKey: .mediaType)
                try source.encode(data.base64EncodedString(), forKey: .data)
            }
        case .audio:
            throw LLMError.unsupported("AnthropicProvider does not support audio content blocks.")
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }
}

private struct WireTool: Encodable {
    let name: String
    let description: String
    let input_schema: JSONValue

    init(_ descriptor: ToolDescriptor) {
        self.name = descriptor.name
        self.description = descriptor.description
        self.input_schema = descriptor.inputSchema
    }
}

private struct WireResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
    let content: [Block]
    let stop_reason: String?
    let usage: Usage?

    func toResponse() -> LLMResponse {
        let blocks: [ContentBlock] = content.compactMap { block in
            switch block.type {
            case "text":
                return .text(block.text ?? "")
            case "thinking", "redacted_thinking":
                return .reasoning(block.thinking ?? block.text ?? "")
            case "tool_use":
                return .toolUse(
                    id: block.id ?? "",
                    name: block.name ?? "",
                    input: block.input ?? .object([:])
                )
            default:
                return nil
            }
        }
        let stop: StopReason
        switch stop_reason {
        case "end_turn": stop = .endTurn
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case "stop_sequence": stop = .stopSequence
        case let other?: stop = .other(other)
        case nil: stop = .endTurn
        }
        return LLMResponse(
            content: blocks,
            stopReason: stop,
            usage: TokenUsage(
                inputTokens: usage?.input_tokens ?? 0,
                outputTokens: usage?.output_tokens ?? 0
            )
        )
    }
}

private struct StreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let partial_json: String?
        let stop_reason: String?
    }
    struct Block: Decodable {
        let type: String?
        let id: String?
        let name: String?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
    struct StartMessage: Decodable {
        let usage: Usage?
    }
    let type: String
    let index: Int?
    let delta: Delta?
    let content_block: Block?
    let usage: Usage?
    let message: StartMessage?

    /// Anthropic reports usage across two events: input tokens arrive in
    /// `message_start`, the final output count in `message_delta`. The
    /// Orchestrator merges these (it keeps the max of each field), so emitting
    /// a partial `TokenUsage` from each event is correct.
    func chunks(activeToolIDs: inout [Int: String]) -> [LLMResponseChunk] {
        switch type {
        case "message_start":
            if let usage = message?.usage {
                return [.usage(TokenUsage(
                    inputTokens: usage.input_tokens ?? 0,
                    outputTokens: usage.output_tokens ?? 0
                ))]
            }
            return []
        case "content_block_start":
            if content_block?.type == "tool_use" {
                let toolID = content_block?.id ?? String(index ?? 0)
                if let index {
                    activeToolIDs[index] = toolID
                }
                return [.toolUseStart(
                    id: toolID,
                    name: content_block?.name ?? ""
                )]
            }
            return []
        case "content_block_delta":
            if let text = delta?.text {
                return [.textDelta(text)]
            }
            if let thinking = delta?.thinking {
                return [.reasoningDelta(thinking)]
            }
            if let json = delta?.partial_json {
                let toolID = index.flatMap { activeToolIDs[$0] } ?? String(index ?? 0)
                return [.toolUseInputDelta(id: toolID, json: json)]
            }
            return []
        case "content_block_stop":
            guard let index, let toolID = activeToolIDs.removeValue(forKey: index) else {
                return []
            }
            return [.toolUseStop(id: toolID)]
        case "message_delta":
            var result: [LLMResponseChunk] = []
            if let reason = delta?.stop_reason {
                let stop: StopReason
                switch reason {
                case "end_turn": stop = .endTurn
                case "tool_use": stop = .toolUse
                case "max_tokens": stop = .maxTokens
                case "stop_sequence": stop = .stopSequence
                default: stop = .other(reason)
                }
                result.append(.stop(stop))
            }
            if let usage {
                result.append(.usage(TokenUsage(
                    inputTokens: usage.input_tokens ?? 0,
                    outputTokens: usage.output_tokens ?? 0
                )))
            }
            return result
        case "message_stop":
            if let usage {
                return [.usage(TokenUsage(
                    inputTokens: usage.input_tokens ?? 0,
                    outputTokens: usage.output_tokens ?? 0
                ))]
            }
            return []
        default:
            return []
        }
    }
}
