import Foundation
import FoundationModels

public struct VolcengineArkConfiguration: Sendable, Hashable {
    public static let defaultBaseURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
    public static let defaultChatCompletionsPath = "chat/completions"

    public var apiKey: String
    public var baseURL: URL
    public var model: String
    public var chatCompletionsPath: String
    public var timeout: TimeInterval?
    /// Vendor body extensions keyed by their top-level wire field.
    /// `GeneratedContent` is the official JSON currency; values are merged
    /// into the request body right at the wire via `jsonString`, never
    /// interpreted above it.
    public var defaultExtraBody: [String: GeneratedContent]
    public var extraHeaders: [String: String]

    /// The package-owned wire defaults: thinking OFF and reasoning effort
    /// pinned to minimal. Provider configuration lives here — hosts describe
    /// requests (messages, tools, an optional response schema) and the
    /// provider package decides the vendor body extensions. The official
    /// `ContextOptions.reasoningLevel` overrides these per request on the
    /// FoundationModels executor path.
    public static let defaultWireExtraBody: [String: GeneratedContent] = [
        "thinking": GeneratedContent(properties: ["type": "disabled"]),
        "reasoning_effort": GeneratedContent("minimal"),
    ]

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = Self.defaultBaseURL,
        chatCompletionsPath: String = Self.defaultChatCompletionsPath,
        timeout: TimeInterval? = nil,
        defaultExtraBody: [String: GeneratedContent] = Self.defaultWireExtraBody,
        extraHeaders: [String: String] = [:]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.chatCompletionsPath = chatCompletionsPath
        self.timeout = timeout
        self.defaultExtraBody = defaultExtraBody
        self.extraHeaders = extraHeaders
    }

    // `GeneratedContent` is `Equatable` but not `Hashable`, so the
    // `LanguageModelExecutor.Configuration` requirement is met by hashing
    // the extras through their canonical JSON encoding.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(apiKey)
        hasher.combine(baseURL)
        hasher.combine(model)
        hasher.combine(chatCompletionsPath)
        hasher.combine(timeout)
        for key in defaultExtraBody.keys.sorted() {
            hasher.combine(key)
            hasher.combine(defaultExtraBody[key]?.jsonString)
        }
        hasher.combine(extraHeaders)
    }
}

public struct VolcengineArkLanguageModel: LanguageModel, Sendable {
    public typealias Executor = VolcengineArkLanguageModelExecutor

    public static let defaultCapabilities = LanguageModelCapabilities(
        capabilities: [.toolCalling, .reasoning]
    )

    public var configuration: VolcengineArkConfiguration
    public var capabilities: LanguageModelCapabilities

    public var executorConfiguration: VolcengineArkLanguageModelExecutor.Configuration {
        configuration
    }

    public init(
        configuration: VolcengineArkConfiguration,
        capabilities: LanguageModelCapabilities = Self.defaultCapabilities
    ) {
        self.configuration = configuration
        self.capabilities = capabilities
    }

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = VolcengineArkConfiguration.defaultBaseURL,
        timeout: TimeInterval? = nil,
        capabilities: LanguageModelCapabilities = Self.defaultCapabilities
    ) {
        self.init(
            configuration: .init(
                apiKey: apiKey,
                model: model,
                baseURL: baseURL,
                timeout: timeout
            ),
            capabilities: capabilities
        )
    }
}

public struct VolcengineArkLanguageModelExecutor: LanguageModelExecutor, Sendable {
    public typealias Configuration = VolcengineArkConfiguration
    public typealias Model = VolcengineArkLanguageModel

    public let configuration: VolcengineArkConfiguration
    private let session: URLSession

    public init(configuration: VolcengineArkConfiguration) throws {
        try self.init(configuration: configuration, session: .shared)
    }

    public init(
        configuration: VolcengineArkConfiguration,
        session: URLSession = .shared
    ) throws {
        self.configuration = configuration
        self.session = session
    }

    private var client: VolcengineArkClient {
        VolcengineArkClient(configuration: configuration, session: session)
    }
    
    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: VolcengineArkLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var extraBody = Self.extraBody(for: request.contextOptions)
        if extraBody.isEmpty {
            extraBody = configuration.defaultExtraBody
        }
        // Foundation Models tool-calling mode maps onto Ark's OpenAI-style
        // `tool_choice`. `required` makes the model emit ONLY tool calls (no
        // prose preamble) — the lever for single-purpose routing stages.
        // Guided generation (`request.schema`) becomes the wire's
        // `response_format` constraint inside the wire encoder.
        switch request.generationOptions.toolCallingMode?.kind {
        case .required:
            extraBody["tool_choice"] = GeneratedContent("required")
        case .disallowed:
            extraBody["tool_choice"] = GeneratedContent("none")
        default:
            break  // .allowed / nil → Ark's default "auto"
        }

        let started = ContinuousClock.now
        let entryID = UUID().uuidString
        await channel.send(.response(
            entryID: entryID,
            action: .updateMetadata([
                "modelID": model.configuration.model,
                "requestID": request.id.uuidString,
            ])
        ))

        let usage = try await client.respond(
            model: model.configuration.model,
            transcript: request.transcript,
            toolDefinitions: request.enabledToolDefinitions,
            schema: request.schema,
            options: request.generationOptions,
            extraBody: extraBody,
            entryID: entryID,
            streamingInto: channel
        )

        let elapsed = ContinuousClock.now - started
        VolcengineArkUsageMonitor.report(
            usage: usage,
            model: model.configuration.model,
            duration: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        )
        await channel.send(.response(
            entryID: entryID,
            action: .updateUsage(input: usage.input, output: usage.output)
        ))
    }

    private static func extraBody(
        for contextOptions: ContextOptions
    ) -> [String: GeneratedContent] {
        guard let reasoningLevel = contextOptions.reasoningLevel else { return [:] }
        return [
            "thinking": GeneratedContent(properties: ["type": "enabled"]),
            "reasoning_effort": GeneratedContent(reasoningLevel.arkReasoningEffort),
        ]
    }
}

struct VolcengineArkClient: Sendable {
    let configuration: VolcengineArkConfiguration
    private let session: URLSession

    init(
        configuration: VolcengineArkConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    /// Runs one streaming chat-completions call, translating SSE chunks into
    /// official channel events as they arrive. Returns the usage totals for
    /// the call; the caller sends the final `updateUsage`. Cancellation ends
    /// the stream cleanly, so a cancelled request still reports the usage
    /// seen so far.
    func respond(
        model: String,
        transcript: Transcript,
        toolDefinitions: [Transcript.ToolDefinition],
        schema: GenerationSchema?,
        options: GenerationOptions,
        extraBody: [String: GeneratedContent],
        entryID: String,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws -> LanguageModelExecutorGenerationChannel.Usage {
        let urlRequest = try makeURLRequest(
            model: model,
            transcript: transcript,
            toolDefinitions: toolDefinitions,
            schema: schema,
            options: options,
            extraBody: extraBody
        )
        #if DEBUG
        VolcengineArkWireTrace.report(.request(
            model: model.trimmedNonEmpty ?? configuration.model,
            body: urlRequest.httpBody ?? Data()
        ))
        #endif
        var accumulator = StreamAccumulator()
        do {
            let bytes = try await validatedBytes(for: urlRequest)
            for try await line in bytes.lines {
                try Task.checkCancellation()
                #if DEBUG
                VolcengineArkWireTrace.report(.responseLine(line))
                #endif
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !json.isEmpty else { continue }
                if json == "[DONE]" { break }
                guard let data = json.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamWireEvent.self, from: data)
                else { continue }
                await forward(chunk, into: channel, entryID: entryID, accumulator: &accumulator)
            }
        } catch is CancellationError {
            // Clean early stop; partial usage still reaches the caller.
        } catch let error as VolcengineArkError {
            throw error
        } catch let error as LanguageModelError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
        return accumulator.usage
    }

    /// One decoded SSE chunk becomes zero or more channel events. Usage
    /// chunks fold into the accumulator instead of being sent: Ark may
    /// report usage across several trailing chunks, and the channel should
    /// see one final `updateUsage`.
    private func forward(
        _ chunk: StreamWireEvent,
        into channel: LanguageModelExecutorGenerationChannel,
        entryID: String,
        accumulator: inout StreamAccumulator
    ) async {
        for choice in chunk.choices {
            if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                let tokenCount = estimatedTokenCount(reasoning)
                accumulator.estimatedReasoningTokens += tokenCount
                await channel.send(.reasoning(
                    entryID: entryID,
                    action: .appendText(reasoning, tokenCount: tokenCount)
                ))
            }
            if let text = choice.delta.content, !text.isEmpty {
                await channel.send(.response(
                    entryID: entryID,
                    action: .appendText(text, tokenCount: estimatedTokenCount(text))
                ))
            }
            for call in choice.delta.tool_calls ?? [] {
                let index = call.index ?? 0
                if let id = call.id, accumulator.activeTools[index] == nil {
                    let name = call.function.name ?? ""
                    accumulator.activeTools[index] = (id: id, name: name)
                    // Announce the call: an empty fragment carries id + name
                    // before any argument bytes arrive.
                    await channel.send(.toolCalls(
                        entryID: entryID,
                        action: .toolCall(
                            id: id,
                            name: name,
                            action: .appendArguments("", tokenCount: 0)
                        )
                    ))
                }
                if let arguments = call.function.arguments, !arguments.isEmpty {
                    let tool = accumulator.activeTools[index]
                    await channel.send(.toolCalls(
                        entryID: entryID,
                        action: .toolCall(
                            id: tool?.id ?? String(index),
                            name: tool?.name ?? "",
                            action: .appendArguments(
                                arguments,
                                tokenCount: estimatedTokenCount(arguments)
                            )
                        )
                    ))
                }
            }
            if let finishReason = choice.finish_reason {
                accumulator.activeTools.removeAll()
                // The channel has no first-class stop event; consumers
                // recover the OpenAI-compatible finish reason from entry
                // metadata.
                await channel.send(.response(
                    entryID: entryID,
                    action: .updateMetadata(["finishReason": finishReason])
                ))
            }
        }
        if let usage = chunk.usage {
            accumulator.merge(usage)
        }
    }

    private static let reservedBodyKeys: Set<String> = [
        "model", "messages", "tools", "temperature", "max_tokens",
        "stream", "stream_options",
    ]

    private func makeURLRequest(
        model: String,
        transcript: Transcript,
        toolDefinitions: [Transcript.ToolDefinition],
        schema: GenerationSchema?,
        options: GenerationOptions,
        extraBody: [String: GeneratedContent]
    ) throws -> URLRequest {
        let endpoint = try configuration.baseURL.resolvingEndpointPath(
            configuration.chatCompletionsPath
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw VolcengineArkError.missingAPIKey }
        urlRequest.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in configuration.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let timeout = configuration.timeout {
            urlRequest.timeoutInterval = timeout
        }

        let wire = WireRequest(
            model: model.trimmedNonEmpty ?? configuration.model,
            transcript: transcript,
            toolDefinitions: toolDefinitions,
            schema: schema,
            options: options
        )
        let mergedExtraBody = configuration.defaultExtraBody.merging(extraBody) {
            _, override in override
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(wire)
        } catch {
            throw VolcengineArkError.encodingFailed(String(describing: error))
        }
        // Guided generation owns `response_format`; body extensions must not
        // override the schema constraint.
        let reservedKeys = schema == nil
            ? Self.reservedBodyKeys
            : Self.reservedBodyKeys.union(["response_format"])
        urlRequest.httpBody = try mergedRequestBody(
            encoded: encoded,
            extraBody: mergedExtraBody,
            reservedKeys: reservedKeys
        )
        return urlRequest
    }

    private func validatedBytes(for request: URLRequest) async throws -> URLSession.AsyncBytes {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.transportError(error)
        }
        try validate(response)
        return bytes
    }

    /// The bytes API exposes no error body before streaming begins, so
    /// non-2xx failures carry the status code alone.
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // Shapes the official taxonomy models surface as
            // `LanguageModelError`, so session-side handling (rate-limit
            // backoff) works without knowing the Ark error type.
            if http.statusCode == 429 {
                throw LanguageModelError.rateLimited(.init(
                    resetDate: nil,
                    debugDescription: "Volcengine Ark HTTP 429"
                ))
            }
            throw VolcengineArkError.httpStatus(code: http.statusCode, body: "")
        }
    }

    /// Maps a transport failure onto the official taxonomy where a
    /// counterpart exists (timeout, cancellation); everything else stays the
    /// provider-specific `VolcengineArkError`.
    static func transportError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else {
            return VolcengineArkError.transport(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return LanguageModelError.timeout(.init(
                debugDescription: urlError.localizedDescription
            ))
        case .badURL, .unsupportedURL:
            return VolcengineArkError.unsupported(urlError.localizedDescription)
        default:
            return VolcengineArkError.transport(
                "\(urlError.code.rawValue): \(urlError.localizedDescription)"
            )
        }
    }
}

/// Per-request state the stream needs above individual chunks: tool-call
/// identity by choice index, and the best usage numbers seen so far, kept
/// directly in the official channel `Usage` currency.
private struct StreamAccumulator {
    /// Tool-call argument deltas arrive keyed by choice index without id or
    /// name; channel fragments need both on every event.
    var activeTools: [Int: (id: String, name: String)] = [:]

    /// Reasoning tokens estimated from streamed text, used only when the
    /// wire never reports `reasoning_tokens`.
    var estimatedReasoningTokens = 0

    private var reported = LanguageModelExecutorGenerationChannel.Usage(
        input: .init(totalTokenCount: 0, cachedTokenCount: 0),
        output: .init(totalTokenCount: 0, reasoningTokenCount: 0)
    )

    /// Ark may report usage across several trailing chunks; keep the largest
    /// seen of each field.
    mutating func merge(_ usage: StreamWireEvent.Usage) {
        reported.input.totalTokenCount = max(
            reported.input.totalTokenCount, usage.prompt_tokens ?? 0
        )
        reported.input.cachedTokenCount = max(
            reported.input.cachedTokenCount,
            usage.prompt_tokens_details?.cached_tokens ?? 0
        )
        reported.output.totalTokenCount = max(
            reported.output.totalTokenCount, usage.completion_tokens ?? 0
        )
        reported.output.reasoningTokenCount = max(
            reported.output.reasoningTokenCount,
            usage.completion_tokens_details?.reasoning_tokens ?? 0
        )
    }

    var usage: LanguageModelExecutorGenerationChannel.Usage {
        var usage = reported
        if usage.output.reasoningTokenCount == 0 {
            usage.output.reasoningTokenCount = estimatedReasoningTokens
        }
        return usage
    }
}

/// Cheap chars/4 token estimate for streaming fragments; the wire's usage
/// totals supersede it once they arrive.
private func estimatedTokenCount(_ text: String) -> Int {
    max(1, (text.count + 3) / 4)
}

/// Provider-specific failures the official `LanguageModelError` taxonomy
/// does not model. Shapes it does model (rate limiting, timeouts,
/// cancellation) are thrown as `LanguageModelError` / `CancellationError`
/// at the wire instead of being mirrored here.
public enum VolcengineArkError: Error, Sendable, Hashable {
    case httpStatus(code: Int, body: String)
    case encodingFailed(String)
    case missingAPIKey
    case transport(String)
    case unsupported(String)
}

extension VolcengineArkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            "Volcengine Ark HTTP \(code): \(body)"
        case .encodingFailed(let detail):
            "Volcengine Ark request encoding failed: \(detail)"
        case .missingAPIKey:
            "Volcengine Ark configuration is missing an API key"
        case .transport(let detail):
            "Volcengine Ark transport error: \(detail)"
        case .unsupported(let detail):
            "Unsupported Volcengine Ark operation: \(detail)"
        }
    }
}

// MARK: - Wire encoding
//
// The only place Foundation Models values become Ark JSON. Everything above
// this layer speaks `Transcript`, `Transcript.ToolDefinition`,
// `GenerationSchema`, `GenerationOptions`, and `GeneratedContent`; the
// chat-completions shape exists from here down, built immediately before the
// request is sent.

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?
    let response_format: WireResponseFormat?
    let temperature: Double?
    let max_tokens: Int?
    let stream = true
    let stream_options = StreamOptions(include_usage: true)

    struct StreamOptions: Encodable {
        let include_usage: Bool
    }

    init(
        model: String,
        transcript: Transcript,
        toolDefinitions: [Transcript.ToolDefinition],
        schema: GenerationSchema?,
        options: GenerationOptions
    ) {
        self.model = model
        let messages = WireMessage.messages(from: transcript)
        // Ark rejects an empty messages array; an empty transcript still
        // sends one (empty) user turn.
        self.messages = messages.isEmpty
            ? [WireMessage(role: "user", content: .text(""))]
            : messages
        self.tools = toolDefinitions.isEmpty ? nil : toolDefinitions.map(WireTool.init)
        self.response_format = schema.map { WireResponseFormat($0) }
        self.temperature = options.temperature
        self.max_tokens = options.maximumResponseTokens
    }
}

/// Ark's strict `json_schema` response constraint, embedding the
/// `GenerationSchema`'s official JSON encoding inline.
private struct WireResponseFormat: Encodable {
    struct Schema: Encodable {
        let name: String
        let schema: GenerationSchema
        let strict: Bool
    }

    let type = "json_schema"
    let json_schema: Schema

    init(_ schema: GenerationSchema, name: String = "response") {
        self.json_schema = Schema(name: name, schema: schema, strict: true)
    }
}

private struct WireMessage: Encodable {
    let role: String
    var content: WireMessageContent?
    var tool_calls: [WireToolCall]?
    var tool_call_id: String?

    init(
        role: String,
        content: WireMessageContent? = nil,
        toolCalls: [WireToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = toolCalls
        self.tool_call_id = toolCallID
    }

    /// Transcript entries map onto chat-completions messages.
    static func messages(from transcript: Transcript) -> [WireMessage] {
        var messages: [WireMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                if let text = flattenedText(from: instructions.segments) {
                    messages.append(WireMessage(role: "system", content: .text(text)))
                }
            case .prompt(let prompt):
                if let content = WireMessageContent(segments: prompt.segments) {
                    messages.append(WireMessage(role: "user", content: content))
                }
            case .response(let response):
                if let text = flattenedText(from: response.segments) {
                    messages.append(WireMessage(role: "assistant", content: .text(text)))
                }
            case .reasoning:
                // Chat-completions backends expect prior reasoning NOT to be
                // re-sent as assistant turns: replaying it inflates context
                // and skews the continuation. The entry stays in the FM
                // transcript for the host; the wire never sees it.
                continue
            case .toolCalls(let toolCalls):
                messages.append(WireMessage(
                    role: "assistant",
                    toolCalls: toolCalls.map(WireToolCall.init)
                ))
            case .toolOutput(let output):
                if let text = flattenedText(from: output.segments) {
                    messages.append(WireMessage(
                        role: "tool",
                        content: .text(text),
                        toolCallID: output.id
                    ))
                }
            @unknown default:
                continue
            }
        }
        return messages
    }
}

private enum WireMessageContent: Encodable {
    case text(String)
    case parts([WireContentPart])

    /// Ark accepts these `detail` values on `image_url` parts; any other
    /// attachment label is a caption, not a detail hint.
    private static let imageDetailValues: Set<String> = ["low", "high", "auto"]

    /// User-prompt content. Text-only prompts stay a plain string; image
    /// attachments become OpenAI-style `image_url` parts carrying the
    /// attachment's URL (remote or `data:`) verbatim.
    init?(segments: [Transcript.Segment]) {
        var parts: [WireContentPart] = []
        var hasMedia = false
        for segment in segments {
            switch segment {
            case .text(let text):
                parts.append(.text(text.content))
            case .structure(let structured):
                parts.append(.text(structured.description))
            case .attachment(let attachment):
                switch attachment.content {
                case .image(let image):
                    guard let url = image.url else {
                        // CGImage-backed attachments have no transportable
                        // URL; describe them rather than dropping the segment.
                        parts.append(.text(attachment.description))
                        continue
                    }
                    let detail = attachment.label.flatMap {
                        Self.imageDetailValues.contains($0) ? $0 : nil
                    }
                    parts.append(.imageURL(url.absoluteString, detail: detail))
                    hasMedia = true
                @unknown default:
                    parts.append(.text(attachment.description))
                }
            case .custom(let custom):
                parts.append(.text(custom.description))
            @unknown default:
                continue
            }
        }
        if hasMedia {
            self = .parts(parts)
            return
        }
        let text = parts.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }
        .joined(separator: "\n")
        guard let trimmed = text.trimmedNonEmpty else { return nil }
        self = .text(trimmed)
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
    case imageURL(String, detail: String?)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    enum ImageURLKeys: String, CodingKey {
        case url, detail
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url, let detail):
            try container.encode("image_url", forKey: .type)
            var nested = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            try nested.encode(url, forKey: .url)
            try nested.encodeIfPresent(detail, forKey: .detail)
        }
    }
}

private struct WireTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: GenerationSchema
    }

    let type = "function"
    let function: Function

    init(_ definition: Transcript.ToolDefinition) {
        self.function = Function(
            name: definition.name,
            description: definition.description,
            parameters: definition.parameters
        )
    }
}

private struct WireToolCall: Codable {
    struct Function: Codable {
        let name: String?
        let arguments: String?
    }

    var id: String?
    let type: String?
    let function: Function
    var index: Int?

    init(_ call: Transcript.ToolCall) {
        self.id = call.id
        self.type = "function"
        // `jsonString` is the official GeneratedContent → JSON conversion.
        self.function = Function(name: call.toolName, arguments: call.arguments.jsonString)
        self.index = nil
    }
}

/// Flattens transcript segments to wire text, or `nil` when nothing remains.
private func flattenedText(from segments: [Transcript.Segment]) -> String? {
    segments.map { segment in
        switch segment {
        case .text(let text):
            text.content
        case .structure(let structured):
            structured.description
        case .attachment(let attachment):
            attachment.description
        case .custom(let custom):
            custom.description
        @unknown default:
            ""
        }
    }
    .joined(separator: "\n")
    .trimmedNonEmpty
}

private struct StreamWireEvent: Decodable {
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
        struct PromptTokensDetails: Decodable {
            let cached_tokens: Int?
        }

        struct CompletionTokensDetails: Decodable {
            let reasoning_tokens: Int?
        }

        let prompt_tokens: Int?
        let completion_tokens: Int?
        let prompt_tokens_details: PromptTokensDetails?
        let completion_tokens_details: CompletionTokensDetails?
    }

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
}

private func mergedRequestBody(
    encoded: Data,
    extraBody: [String: GeneratedContent],
    reservedKeys: Set<String>
) throws -> Data {
    guard !extraBody.isEmpty else { return encoded }
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        return encoded
    }
    // `jsonString` is the official GeneratedContent → JSON conversion;
    // scalar extensions ("minimal", true) arrive as JSON fragments.
    for (key, value) in extraBody where !reservedKeys.contains(key) {
        object[key] = try JSONSerialization.jsonObject(
            with: Data(value.jsonString.utf8),
            options: [.fragmentsAllowed]
        )
    }
    return try JSONSerialization.data(withJSONObject: object)
}

private extension URL {
    func resolvingEndpointPath(_ endpointPath: String) throws -> URL {
        let trimmed = endpointPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        let slash = CharacterSet(charactersIn: "/")
        let normalized = trimmed.trimmingCharacters(in: slash)
        guard !normalized.isEmpty else {
            throw VolcengineArkError.unsupported("endpoint path must not be empty")
        }

        let endpointComponents = URLComponents(string: normalized)
        let endpoint = (endpointComponents?.path ?? normalized).trimmingCharacters(in: slash)
        let components = endpoint.split(separator: "/", omittingEmptySubsequences: true)
        let first = components.first.map(String.init)
        let remainder = components.dropFirst().joined(separator: "/")
        let baseComponents = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let basePath = (baseComponents?.path ?? "").trimmingCharacters(in: slash)
        let baseEndsWith: (String) -> Bool = { suffix in
            basePath == suffix || basePath.hasSuffix("/\(suffix)")
        }

        if baseEndsWith(endpoint) || (!remainder.isEmpty && baseEndsWith(remainder)) {
            return self
        }

        var resolved = baseComponents
        let pathToAppend: String
        if let first, baseEndsWith(first) {
            pathToAppend = remainder
        } else {
            pathToAppend = endpoint
        }
        let resolvedPath = [basePath, pathToAppend]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        resolved?.path = resolvedPath.isEmpty ? "" : "/\(resolvedPath)"
        resolved?.percentEncodedQuery = endpointComponents?.percentEncodedQuery
        resolved?.percentEncodedFragment = endpointComponents?.percentEncodedFragment

        guard let url = resolved?.url else {
            throw VolcengineArkError.unsupported("invalid endpoint URL")
        }
        return url
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ContextOptions.ReasoningLevel {
    var arkReasoningEffort: String {
        switch self {
        case .light:
            "low"
        case .moderate:
            "medium"
        case .deep:
            "high"
        case .custom(let value):
            value
        @unknown default:
            "minimal"
        }
    }
}
