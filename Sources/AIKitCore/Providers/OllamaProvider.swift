import Foundation

/// `LLMProvider` backed by Ollama's native `/api/chat` endpoint.
///
/// Unlike pointing `OpenAIProvider` at Ollama's OpenAI-compatible shim, this
/// talks to the native API directly: native tool calling, native `options`
/// (`num_ctx`, `top_p`, `seed`, `stop`, …) and `keep_alive`. No API key is
/// required; one is sent only if the configuration provides a non-empty key
/// (for reverse-proxied deployments).
///
/// Ollama streams newline-delimited JSON (not SSE), and emits `tool_calls` as
/// a single complete block rather than incremental deltas.
public struct OllamaProvider: LLMProvider {
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    public let configuration: LLMProviderConfiguration

    /// Ollama tool support is a property of the *model*, not the endpoint:
    /// `llama3.1` emits native `tool_calls`, but `gemma`, `phi`, and most older
    /// tags emit neither `tool_calls` nor a fenced block. A single
    /// provider-level boolean can't express that, so this reports `false`: the
    /// Runtime then enables the fenced-`tool` fallback by default, which is
    /// additive (it only fires when there is no native call and a fenced block
    /// is present), so native-capable models are unaffected while tool-less
    /// ones still work. A host that knows its model calls tools natively can
    /// pin `Orchestrator.Options.toolCallFallback = false` to opt out.
    public var supportsNativeTools: Bool { false }

    public init(configuration: LLMProviderConfiguration) {
        self.configuration = configuration
    }

    public init(
        model: String? = nil,
        availableModels: [String] = [],
        baseURL: URL = OllamaProvider.defaultBaseURL,
        apiKey: String = "",
        timeout: TimeInterval? = nil,
        session: URLSession = .shared
    ) {
        self.init(configuration: .init(
            apiKey: apiKey,
            baseURL: baseURL,
            defaultModel: model,
            availableModels: availableModels,
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
            return try JSONDecoder().decode(WireResponse.self, from: data).toResponse()
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
                    var toolIndex = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty,
                              let payload = trimmed.data(using: .utf8),
                              let event = try? JSONDecoder().decode(WireResponse.self, from: payload)
                        else { continue }
                        for chunk in event.chunks(toolIndex: &toolIndex) {
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

    /// `options` sub-keys owned by the wire encoder; `extraBody` may not
    /// override these.
    private static let reservedOptionKeys: Set<String> = [
        "temperature", "num_predict",
    ]

    private func makeURLRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        if request.audioOutput != nil {
            throw LLMError.unsupported(
                "OllamaProvider does not support generated audio output."
            )
        }
        let url = try configuration.baseURL.resolvingEndpoint(
            apiPrefix: "api", endpoint: "chat"
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

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": .bool(stream),
            "messages": .array(try Self.wireMessages(request)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(Self.wireTool))
        }

        var options: [String: JSONValue] = [:]
        if let temperature = request.temperature {
            options["temperature"] = .number(temperature)
        }
        if let maxTokens = request.maxTokens {
            options["num_predict"] = .int(maxTokens)
        }
        // `keep_alive` is a top-level Ollama key; everything else flows into
        // `options` (num_ctx, top_p, seed, stop, …) unless it shadows a
        // reserved key the encoder already set.
        for (key, value) in request.extraBody {
            if key == "keep_alive" {
                body["keep_alive"] = value
            } else if !Self.reservedOptionKeys.contains(key) {
                options[key] = value
            }
        }
        if !options.isEmpty {
            body["options"] = .object(options)
        }

        do {
            urlRequest.httpBody = try JSONValue.object(body).data()
        } catch {
            throw LLMError.encodingFailed(String(describing: error))
        }
        return urlRequest
    }

    private static func wireMessages(_ request: LLMRequest) throws -> [JSONValue] {
        var messages: [JSONValue] = []
        if let system = request.system, !system.isEmpty {
            messages.append(.object(["role": .string("system"), "content": .string(system)]))
        }
        for message in request.messages {
            switch message.role {
            case .system:
                messages.append(.object([
                    "role": .string("system"),
                    "content": .string(message.plainText),
                ]))
            case .user:
                var object: [String: JSONValue] = [
                    "role": .string("user"),
                    "content": .string(message.plainText),
                ]
                let images = try Self.ollamaImages(in: message)
                if !images.isEmpty {
                    object["images"] = .array(images.map(JSONValue.string))
                }
                messages.append(.object(object))
            case .assistant:
                var object: [String: JSONValue] = [
                    "role": .string("assistant"),
                    "content": .string(message.plainText),
                ]
                let toolCalls: [JSONValue] = message.content.compactMap { block in
                    if case .toolUse(_, let name, let input) = block {
                        return .object(["function": .object([
                            "name": .string(name),
                            "arguments": input,
                        ])])
                    }
                    return nil
                }
                if !toolCalls.isEmpty {
                    object["tool_calls"] = .array(toolCalls)
                }
                messages.append(.object(object))
            case .tool:
                for block in message.content {
                    if case .toolResult(_, let content, _) = block {
                        messages.append(.object([
                            "role": .string("tool"),
                            "content": .string(content),
                        ]))
                    }
                }
            }
        }
        return messages
    }

    private static func ollamaImages(in message: Message) throws -> [String] {
        if !message.audio.isEmpty {
            throw LLMError.unsupported("OllamaProvider does not support audio content blocks.")
        }
        return try message.images.map { image in
            switch image.source {
            case .data(_, let data):
                return data.base64EncodedString()
            case .url:
                throw LLMError.unsupported(
                    "OllamaProvider image content requires base64 image data, not a remote URL."
                )
            }
        }
    }

    private static func wireTool(_ descriptor: ToolDescriptor) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(descriptor.name),
                "description": .string(descriptor.description),
                "parameters": descriptor.inputSchema,
            ]),
        ])
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

private struct WireResponse: Decodable {
    struct WireMessage: Decodable {
        struct ToolCall: Decodable {
            struct Function: Decodable {
                let name: String
                let arguments: JSONValue?
            }
            let function: Function
        }
        let content: String?
        // Reasoning-capable local models (gemma, qwq, deepseek-r1, …) return
        // chain-of-thought here alongside `content` on `/api/chat`.
        let thinking: String?
        let tool_calls: [ToolCall]?
    }
    let message: WireMessage?
    let done: Bool?
    let done_reason: String?
    let prompt_eval_count: Int?
    let eval_count: Int?

    private var hasToolCalls: Bool {
        message?.tool_calls?.isEmpty == false
    }

    /// Tool calls always mean `.toolUse` regardless of `done_reason`; this is
    /// the single source of truth so callers don't re-apply the ternary.
    private func stopReason() -> StopReason {
        if hasToolCalls { return .toolUse }
        switch done_reason {
        case "stop", nil: return .endTurn
        case "length": return .maxTokens
        case let other?: return .other(other)
        }
    }

    private func usage() -> TokenUsage {
        TokenUsage(
            inputTokens: prompt_eval_count ?? 0,
            outputTokens: eval_count ?? 0
        )
    }

    func toResponse() -> LLMResponse {
        var blocks: [ContentBlock] = []
        if let thinking = message?.thinking, !thinking.isEmpty {
            blocks.append(.reasoning(thinking))
        }
        if let text = message?.content, !text.isEmpty {
            blocks.append(.text(text))
        }
        for (offset, call) in (message?.tool_calls ?? []).enumerated() {
            blocks.append(.toolUse(
                id: "ollama-\(offset)",
                name: call.function.name,
                input: call.function.arguments ?? .object([:])
            ))
        }
        return LLMResponse(
            content: blocks,
            stopReason: stopReason(),
            usage: usage()
        )
    }

    /// Converts one streamed NDJSON object into response chunks. Ollama sends
    /// each `tool_call` as a complete block, so we synthesize start/input/stop
    /// in one go.
    func chunks(toolIndex: inout Int) -> [LLMResponseChunk] {
        var result: [LLMResponseChunk] = []
        if let thinking = message?.thinking, !thinking.isEmpty {
            result.append(.reasoningDelta(thinking))
        }
        if let text = message?.content, !text.isEmpty {
            result.append(.textDelta(text))
        }
        for call in message?.tool_calls ?? [] {
            let id = "ollama-\(toolIndex)"
            toolIndex += 1
            result.append(.toolUseStart(id: id, name: call.function.name))
            if let args = call.function.arguments,
               let data = try? args.data(),
               let json = String(data: data, encoding: .utf8) {
                result.append(.toolUseInputDelta(id: id, json: json))
            }
            result.append(.toolUseStop(id: id))
        }
        if done == true {
            result.append(.stop(stopReason()))
            result.append(.usage(usage()))
        }
        return result
    }
}
