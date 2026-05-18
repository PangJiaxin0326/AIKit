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
            return try wire.toResponse()
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
        "model", "messages", "tools", "temperature", "max_tokens",
        "stream", "stream_options",
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
            let wire = WireRequest(request: request, model: request.model, stream: stream)
            urlRequest.httpBody = try mergedRequestBody(
                encoded: JSONEncoder().encode(wire),
                extraBody: request.extraBody,
                reservedKeys: Self.reservedBodyKeys
            )
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
    let stream: Bool
    let stream_options: StreamOptions?

    struct StreamOptions: Encodable {
        let include_usage: Bool
    }

    init(request: LLMRequest, model: String, stream: Bool) {
        self.model = model
        self.stream = stream
        self.stream_options = stream ? StreamOptions(include_usage: true) : nil
        self.temperature = request.temperature
        self.max_tokens = request.maxTokens

        var messages: [WireMessage] = []
        if let system = request.system {
            messages.append(WireMessage(role: "system", content: system))
        }
        for message in request.messages {
            switch message.role {
            case .system:
                messages.append(WireMessage(role: "system", content: message.plainText))
            case .user:
                messages.append(WireMessage(role: "user", content: message.plainText))
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
                messages.append(WireMessage(
                    role: "assistant",
                    content: text.isEmpty ? nil : text,
                    tool_calls: toolCalls.isEmpty ? nil : toolCalls
                ))
            case .tool:
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, _) = block {
                        messages.append(WireMessage(
                            role: "tool",
                            content: content,
                            tool_call_id: toolUseID
                        ))
                    }
                }
            }
        }
        self.messages = messages
        self.tools = request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
    }
}

private struct WireMessage: Encodable {
    let role: String
    var content: String?
    var tool_calls: [WireToolCall]?
    var tool_call_id: String?
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
            let tool_calls: [WireToolCall]?
        }
        let message: Msg
        let finish_reason: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
    let choices: [Choice]
    let usage: Usage?

    func toResponse() throws -> LLMResponse {
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
            let content: String?
            let reasoning_content: String?
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

    func chunks(activeToolIDs: inout [Int: String]) -> [LLMResponseChunk] {
        var result: [LLMResponseChunk] = []
        for choice in choices {
            if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                result.append(.reasoningDelta(reasoning))
            }
            if let text = choice.delta.content, !text.isEmpty {
                result.append(.textDelta(text))
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
