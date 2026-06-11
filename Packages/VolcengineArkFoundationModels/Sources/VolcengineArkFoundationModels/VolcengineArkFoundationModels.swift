import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct VolcengineArkConfiguration: Sendable, Hashable, Codable {
    public static let defaultBaseURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
    public static let defaultChatCompletionsPath = "chat/completions"

    public var apiKey: String
    public var baseURL: URL
    public var model: String
    public var chatCompletionsPath: String
    public var timeout: TimeInterval?
    public var defaultExtraBody: [String: VolcengineArkJSONValue]
    public var extraHeaders: [String: String]
    public var capabilities: Set<VolcengineArkModelCapability>

    /// The package-owned wire defaults: thinking OFF and reasoning effort
    /// pinned to minimal. Provider configuration lives here — hosts describe
    /// requests (messages, tools, an optional response schema) and the
    /// provider package decides the vendor body extensions. The official
    /// `ContextOptions.reasoningLevel` overrides these per request on the
    /// FoundationModels executor path.
    public static let defaultWireExtraBody: [String: VolcengineArkJSONValue] = [
        "thinking": .object(["type": .string("disabled")]),
        "reasoning_effort": .string("minimal"),
    ]

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = Self.defaultBaseURL,
        chatCompletionsPath: String = Self.defaultChatCompletionsPath,
        timeout: TimeInterval? = nil,
        defaultExtraBody: [String: VolcengineArkJSONValue] = Self.defaultWireExtraBody,
        extraHeaders: [String: String] = [:],
        capabilities: Set<VolcengineArkModelCapability> = [.toolCalling, .reasoning]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.chatCompletionsPath = chatCompletionsPath
        self.timeout = timeout
        self.defaultExtraBody = defaultExtraBody
        self.extraHeaders = extraHeaders
        self.capabilities = capabilities
    }
}

public enum VolcengineArkModelCapability: String, Sendable, Hashable, Codable {
    case vision
    case guidedGeneration
    case reasoning
    case toolCalling
}

public struct VolcengineArkLanguageModel: Sendable, Hashable {
    public var configuration: VolcengineArkConfiguration

    public init(configuration: VolcengineArkConfiguration) {
        self.configuration = configuration
    }

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = VolcengineArkConfiguration.defaultBaseURL,
        timeout: TimeInterval? = nil,
        capabilities: Set<VolcengineArkModelCapability> = [.toolCalling, .reasoning]
    ) {
        self.init(configuration: .init(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            timeout: timeout,
            capabilities: capabilities
        ))
    }
}

public struct VolcengineArkLanguageModelExecutor: Sendable {
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

    public func complete(_ request: VolcengineArkRequest) async throws -> VolcengineArkResponse {
        try await client.complete(request)
    }

    public func stream(
        _ request: VolcengineArkRequest
    ) -> AsyncThrowingStream<VolcengineArkStreamEvent, any Error> {
        client.stream(request)
    }

    private var client: VolcengineArkClient {
        VolcengineArkClient(configuration: configuration, session: session)
    }
}

public struct VolcengineArkClient: Sendable {
    public let configuration: VolcengineArkConfiguration
    private let session: URLSession

    public init(
        configuration: VolcengineArkConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func complete(_ request: VolcengineArkRequest) async throws -> VolcengineArkResponse {
        let urlRequest = try makeURLRequest(request, stream: false)
        let data = try await validatedData(for: urlRequest)
        do {
            return try JSONDecoder().decode(WireResponse.self, from: data).response
        } catch let error as VolcengineArkError {
            throw error
        } catch {
            throw VolcengineArkError.decodingFailed(String(describing: error))
        }
    }

    public func stream(
        _ request: VolcengineArkRequest
    ) -> AsyncThrowingStream<VolcengineArkStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request, stream: true)
                    let bytes = try await validatedBytes(for: urlRequest)
                    var activeToolIDs: [Int: String] = [:]
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty else { continue }
                        if json == "[DONE]" { break }
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamWireEvent.self, from: data)
                        else { continue }
                        for chunk in event.events(activeToolIDs: &activeToolIDs) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as VolcengineArkError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: VolcengineArkError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let reservedBodyKeys: Set<String> = [
        "model", "messages", "tools", "temperature", "max_tokens",
        "stream", "stream_options",
    ]

    private func makeURLRequest(
        _ request: VolcengineArkRequest,
        stream: Bool
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

        let wire = WireRequest(request: request, fallbackModel: configuration.model, stream: stream)
        let extraBody = configuration.defaultExtraBody.merging(request.extraBody) {
            _, override in override
        }
        let encoded = try JSONEncoder().encode(wire)
        urlRequest.httpBody = try mergedRequestBody(
            encoded: encoded,
            extraBody: extraBody,
            reservedKeys: Self.reservedBodyKeys
        )
        return urlRequest
    }

    private func validatedData(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VolcengineArkError.from(transport: error)
        }
        try validate(response, data: data)
        return data
    }

    private func validatedBytes(for request: URLRequest) async throws -> URLSession.AsyncBytes {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw VolcengineArkError.from(transport: error)
        }
        try validate(response, data: Data())
        return bytes
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VolcengineArkError.httpStatus(code: http.statusCode, body: body)
        }
    }
}

public struct VolcengineArkRequest: Sendable, Hashable {
    public var model: String?
    public var messages: [VolcengineArkChatMessage]
    public var tools: [VolcengineArkToolDefinition]
    public var temperature: Double?
    public var maxTokens: Int?
    public var extraBody: [String: VolcengineArkJSONValue]

    public init(
        model: String? = nil,
        messages: [VolcengineArkChatMessage],
        tools: [VolcengineArkToolDefinition] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        extraBody: [String: VolcengineArkJSONValue] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extraBody = extraBody
    }
}

public struct VolcengineArkChatMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: VolcengineArkMessageContent?
    public var toolCalls: [VolcengineArkToolCall]
    public var toolCallID: String?

    public init(
        role: Role,
        content: VolcengineArkMessageContent? = nil,
        toolCalls: [VolcengineArkToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public init(role: Role, text: String) {
        self.init(role: role, content: .text(text))
    }
}

public enum VolcengineArkMessageContent: Sendable, Hashable {
    case text(String)
    case parts([VolcengineArkContentPart])
}

public enum VolcengineArkContentPart: Sendable, Hashable {
    case text(String)
    case imageURL(String, detail: String? = nil)
}

public struct VolcengineArkToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: VolcengineArkJSONValue

    public init(
        name: String,
        description: String,
        parameters: VolcengineArkJSONValue
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct VolcengineArkToolCall: Sendable, Hashable {
    public var id: String
    public var name: String
    public var arguments: VolcengineArkJSONValue

    public init(id: String, name: String, arguments: VolcengineArkJSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct VolcengineArkResponse: Sendable, Hashable {
    public var id: String?
    public var model: String?
    public var content: [VolcengineArkContentBlock]
    public var stopReason: VolcengineArkStopReason
    public var usage: VolcengineArkTokenUsage

    public init(
        id: String? = nil,
        model: String? = nil,
        content: [VolcengineArkContentBlock],
        stopReason: VolcengineArkStopReason,
        usage: VolcengineArkTokenUsage = .zero
    ) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    public var text: String {
        content.compactMap(\.text).joined()
    }
}

public enum VolcengineArkContentBlock: Sendable, Hashable {
    case text(String)
    case reasoning(String)
    case toolUse(id: String, name: String, arguments: VolcengineArkJSONValue)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

public enum VolcengineArkStreamEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(id: String, json: String)
    case toolUseStop(id: String)
    case stop(VolcengineArkStopReason)
    case usage(VolcengineArkTokenUsage)
}

public enum VolcengineArkStopReason: Sendable, Hashable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

public struct VolcengineArkTokenUsage: Sendable, Hashable, Codable {
    public static let zero = Self(inputTokens: 0, outputTokens: 0)

    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum VolcengineArkJSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([VolcengineArkJSONValue])
    case object([String: VolcengineArkJSONValue])

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([VolcengineArkJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: VolcengineArkJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}

#if canImport(FoundationModels)
extension VolcengineArkJSONValue {
    /// The Ark `response_format` body extension for a Foundation Models
    /// guided-generation schema: a strict OpenAI-compatible `json_schema`
    /// constraint built from the schema's official JSON encoding.
    public static func responseFormat(
        for schema: GenerationSchema,
        name: String = "response"
    ) throws -> VolcengineArkJSONValue {
        let encoded: VolcengineArkJSONValue
        do {
            encoded = try VolcengineArkJSONValue(data: JSONEncoder().encode(schema))
        } catch {
            throw VolcengineArkError.encodingFailed(
                "Couldn't encode GenerationSchema for response_format: \(error)"
            )
        }
        return .object([
            "type": .string("json_schema"),
            "json_schema": .object([
                "name": .string(name),
                "schema": encoded,
                "strict": .bool(true),
            ]),
        ])
    }
}
#endif

public enum VolcengineArkError: Error, Sendable, Hashable {
    case httpStatus(code: Int, body: String)
    case decodingFailed(String)
    case encodingFailed(String)
    case missingAPIKey
    case missingModel
    case transport(String)
    case timeout(String)
    case cancelled
    case unsupported(String)
    case provider(message: String)

    public static func from(transport error: any Error) -> VolcengineArkError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timeout(urlError.localizedDescription)
            case .badURL, .unsupportedURL:
                return .unsupported(urlError.localizedDescription)
            default:
                return .transport("\(urlError.code.rawValue): \(urlError.localizedDescription)")
            }
        }
        return .transport(error.localizedDescription)
    }
}

extension VolcengineArkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            "Volcengine Ark HTTP \(code): \(body)"
        case .decodingFailed(let detail):
            "Volcengine Ark response decoding failed: \(detail)"
        case .encodingFailed(let detail):
            "Volcengine Ark request encoding failed: \(detail)"
        case .missingAPIKey:
            "Volcengine Ark configuration is missing an API key"
        case .missingModel:
            "Volcengine Ark configuration is missing a model"
        case .transport(let detail):
            "Volcengine Ark transport error: \(detail)"
        case .timeout(let detail):
            "Volcengine Ark request timed out: \(detail)"
        case .cancelled:
            "Volcengine Ark request was cancelled"
        case .unsupported(let detail):
            "Unsupported Volcengine Ark operation: \(detail)"
        case .provider(let message):
            "Volcengine Ark provider error: \(message)"
        }
    }
}

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

    init(
        request: VolcengineArkRequest,
        fallbackModel: String,
        stream: Bool
    ) {
        self.model = request.model?.trimmedNonEmpty ?? fallbackModel
        self.messages = request.messages.map(WireMessage.init)
        self.tools = request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
        self.temperature = request.temperature
        self.max_tokens = request.maxTokens
        self.stream = stream
        self.stream_options = stream ? StreamOptions(include_usage: true) : nil
    }
}

private struct WireMessage: Encodable {
    let role: String
    var content: WireMessageContent?
    var tool_calls: [WireToolCall]?
    var tool_call_id: String?

    init(_ message: VolcengineArkChatMessage) {
        self.role = message.role.rawValue
        self.content = message.content.map(WireMessageContent.init)
        self.tool_calls = message.toolCalls.isEmpty ? nil : message.toolCalls.map(WireToolCall.init)
        self.tool_call_id = message.toolCallID
    }
}

private enum WireMessageContent: Encodable {
    case text(String)
    case parts([WireContentPart])

    init(_ content: VolcengineArkMessageContent) {
        switch content {
        case .text(let text):
            self = .text(text)
        case .parts(let parts):
            self = .parts(parts.map(WireContentPart.init))
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
    case imageURL(String, detail: String?)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    enum ImageURLKeys: String, CodingKey {
        case url, detail
    }

    init(_ part: VolcengineArkContentPart) {
        switch part {
        case .text(let text):
            self = .text(text)
        case .imageURL(let url, let detail):
            self = .imageURL(url, detail: detail)
        }
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
        let parameters: VolcengineArkJSONValue
    }

    let type = "function"
    let function: Function

    init(_ tool: VolcengineArkToolDefinition) {
        self.function = Function(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
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

    init(_ call: VolcengineArkToolCall) {
        self.id = call.id
        self.type = "function"
        self.function = Function(
            name: call.name,
            arguments: (try? call.arguments.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
        self.index = nil
    }
}

private struct WireResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoning_content: String?
            let tool_calls: [WireToolCall]?
        }

        let message: Message
        let finish_reason: String?
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }

    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    var response: VolcengineArkResponse {
        var blocks: [VolcengineArkContentBlock] = []
        guard let choice = choices.first else {
            return VolcengineArkResponse(
                id: id,
                model: model,
                content: [],
                stopReason: .endTurn,
                usage: usageValue
            )
        }
        if let reasoning = choice.message.reasoning_content, !reasoning.isEmpty {
            blocks.append(.reasoning(reasoning))
        }
        if let text = choice.message.content, !text.isEmpty {
            blocks.append(.text(text))
        }
        for call in choice.message.tool_calls ?? [] {
            blocks.append(.toolUse(
                id: call.id ?? "",
                name: call.function.name ?? "",
                arguments: decodedArguments(call.function.arguments)
            ))
        }
        return VolcengineArkResponse(
            id: id,
            model: model,
            content: blocks,
            stopReason: stopReason(choice.finish_reason),
            usage: usageValue
        )
    }

    private var usageValue: VolcengineArkTokenUsage {
        VolcengineArkTokenUsage(
            inputTokens: usage?.prompt_tokens ?? 0,
            outputTokens: usage?.completion_tokens ?? 0
        )
    }
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
        let prompt_tokens: Int?
        let completion_tokens: Int?
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

    func events(activeToolIDs: inout [Int: String]) -> [VolcengineArkStreamEvent] {
        var result: [VolcengineArkStreamEvent] = []
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
                    result.append(.toolUseStart(id: id, name: call.function.name ?? ""))
                }
                if let arguments = call.function.arguments, !arguments.isEmpty {
                    result.append(.toolUseInputDelta(
                        id: activeToolIDs[index] ?? String(index),
                        json: arguments
                    ))
                }
            }
            switch choice.finish_reason {
            case "stop":
                result.append(.stop(.endTurn))
            case "tool_calls":
                for index in activeToolIDs.keys.sorted() {
                    if let id = activeToolIDs.removeValue(forKey: index) {
                        result.append(.toolUseStop(id: id))
                    }
                }
                result.append(.stop(.toolUse))
            case "length":
                result.append(.stop(.maxTokens))
            case let other?:
                result.append(.stop(.other(other)))
            case nil:
                break
            }
        }
        if let usage {
            result.append(.usage(VolcengineArkTokenUsage(
                inputTokens: usage.prompt_tokens ?? 0,
                outputTokens: usage.completion_tokens ?? 0
            )))
        }
        return result
    }
}

private func stopReason(_ reason: String?) -> VolcengineArkStopReason {
    switch reason {
    case "stop":
        .endTurn
    case "tool_calls":
        .toolUse
    case "length":
        .maxTokens
    case let other?:
        .other(other)
    case nil:
        .endTurn
    }
}

private func decodedArguments(_ arguments: String?) -> VolcengineArkJSONValue {
    guard let arguments = arguments?.trimmingCharacters(in: .whitespacesAndNewlines),
          !arguments.isEmpty
    else { return .object([:]) }
    guard let data = arguments.data(using: .utf8),
          let value = try? VolcengineArkJSONValue(data: data)
    else {
        return .object(["__volcengine_ark_malformed_tool_input_raw": .string(arguments)])
    }
    return value
}

private func mergedRequestBody(
    encoded: Data,
    extraBody: [String: VolcengineArkJSONValue],
    reservedKeys: Set<String>
) throws -> Data {
    guard !extraBody.isEmpty else { return encoded }
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        return encoded
    }
    let extraData = try JSONEncoder().encode(extraBody)
    let extra = try JSONSerialization.jsonObject(with: extraData) as? [String: Any] ?? [:]
    for (key, value) in extra where !reservedKeys.contains(key) {
        object[key] = value
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

#if canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension VolcengineArkLanguageModel: FoundationModels.LanguageModel {
    public typealias Executor = VolcengineArkLanguageModelExecutor

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: configuration.capabilities.foundationModelCapabilities)
    }

    public var executorConfiguration: VolcengineArkLanguageModelExecutor.Configuration {
        configuration
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension VolcengineArkLanguageModelExecutor: FoundationModels.LanguageModelExecutor {
    public typealias Configuration = VolcengineArkConfiguration
    public typealias Model = VolcengineArkLanguageModel

    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: VolcengineArkLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let messages = Self.messages(from: request.transcript)
        var extraBody = Self.extraBody(for: request.contextOptions)
        if extraBody.isEmpty {
            extraBody = configuration.defaultExtraBody
        }
        if let schema = request.schema {
            // Foundation Models guided generation maps onto Ark's
            // `response_format` JSON-schema constraint.
            extraBody["response_format"] = try VolcengineArkJSONValue.responseFormat(for: schema)
        }
        let arkRequest = VolcengineArkRequest(
            model: model.configuration.model,
            messages: messages.isEmpty ? [.init(role: .user, text: "")] : messages,
            tools: Self.tools(from: request.enabledToolDefinitions),
            temperature: request.generationOptions.temperature,
            maxTokens: request.generationOptions.maximumResponseTokens,
            extraBody: extraBody
        )

        let response = try await complete(arkRequest)
        let entryID = response.id ?? UUID().uuidString
        await channel.send(.response(
            entryID: entryID,
            action: .updateMetadata([
                "modelID": response.model ?? model.configuration.model,
                "requestID": request.id.uuidString,
            ])
        ))
        for block in response.content {
            switch block {
            case .text(let text):
                await channel.send(.response(
                    entryID: entryID,
                    action: .appendText(text, tokenCount: Self.estimatedTokenCount(text))
                ))
            case .reasoning(let text):
                await channel.send(.reasoning(
                    entryID: entryID,
                    action: .appendText(text, tokenCount: Self.estimatedTokenCount(text))
                ))
            case .toolUse(let id, let name, let arguments):
                let json = (try? arguments.data()).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? "{}"
                await channel.send(.toolCalls(
                    entryID: entryID,
                    action: .toolCall(
                        id: id.isEmpty ? UUID().uuidString : id,
                        name: name,
                        action: .appendArguments(json, tokenCount: Self.estimatedTokenCount(json))
                    )
                ))
            }
        }
        await channel.send(.response(
            entryID: entryID,
            action: .updateUsage(
                input: .init(totalTokenCount: response.usage.inputTokens, cachedTokenCount: 0),
                output: .init(
                    totalTokenCount: response.usage.outputTokens,
                    reasoningTokenCount: response.content.reasoningTokenEstimate
                )
            )
        ))
    }

    private static func messages(from transcript: Transcript) -> [VolcengineArkChatMessage] {
        var messages: [VolcengineArkChatMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                if let text = text(from: instructions.segments).trimmedNonEmpty {
                    messages.append(.init(role: .system, text: text))
                }
            case .prompt(let prompt):
                if let text = text(from: prompt.segments).trimmedNonEmpty {
                    messages.append(.init(role: .user, text: text))
                }
            case .response(let response):
                if let text = text(from: response.segments).trimmedNonEmpty {
                    messages.append(.init(role: .assistant, text: text))
                }
            case .reasoning(let reasoning):
                if let text = text(from: reasoning.segments).trimmedNonEmpty {
                    messages.append(.init(role: .assistant, text: text))
                }
            case .toolCalls(let toolCalls):
                let calls = toolCalls.map { call in
                    VolcengineArkToolCall(
                        id: call.id,
                        name: call.toolName,
                        arguments: jsonValue(from: call.arguments)
                    )
                }
                messages.append(.init(role: .assistant, toolCalls: calls))
            case .toolOutput(let output):
                if let text = text(from: output.segments).trimmedNonEmpty {
                    messages.append(.init(
                        role: .tool,
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

    private static func text(from segments: [Transcript.Segment]) -> String {
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
        }.joined(separator: "\n")
    }

    private static func tools(
        from definitions: [Transcript.ToolDefinition]
    ) -> [VolcengineArkToolDefinition] {
        definitions.map { definition in
            VolcengineArkToolDefinition(
                name: definition.name,
                description: definition.description,
                parameters: jsonValue(from: definition.parameters)
            )
        }
    }

    private static func jsonValue(from value: some Encodable) -> VolcengineArkJSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? VolcengineArkJSONValue(data: data)
        else { return .object([:]) }
        return decoded
    }

    private static func jsonValue(from content: GeneratedContent) -> VolcengineArkJSONValue {
        switch content.kind {
        case .null:
            .null
        case .bool(let value):
            .bool(value)
        case .number(let value):
            .number(value)
        case .string(let value):
            .string(value)
        case .array(let values):
            .array(values.map(jsonValue(from:)))
        case .structure(let properties, _):
            .object(properties.mapValues(jsonValue(from:)))
        @unknown default:
            .string(content.jsonString)
        }
    }

    private static func extraBody(
        for contextOptions: ContextOptions
    ) -> [String: VolcengineArkJSONValue] {
        guard let reasoningLevel = contextOptions.reasoningLevel else { return [:] }
        return [
            "thinking": .object(["type": .string("enabled")]),
            "reasoning_effort": .string(reasoningLevel.arkReasoningEffort),
        ]
    }

    private static func estimatedTokenCount(_ text: String) -> Int {
        Swift.max(1, (text.count + 3) / 4)
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
private extension Set where Element == VolcengineArkModelCapability {
    var foundationModelCapabilities: [LanguageModelCapabilities.Capability] {
        compactMap { capability in
            switch capability {
            case .vision:
                .vision
            case .guidedGeneration:
                .guidedGeneration
            case .reasoning:
                .reasoning
            case .toolCalling:
                .toolCalling
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
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

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
private extension [VolcengineArkContentBlock] {
    var reasoningTokenEstimate: Int {
        reduce(into: 0) { result, block in
            if case .reasoning(let text) = block {
                result += Swift.max(1, (text.count + 3) / 4)
            }
        }
    }
}
#endif
