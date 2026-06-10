import Foundation
import FoundationModels
import AIToolKit
import VolcengineArkFoundationModels

/// `LLMProvider` backed by Volcengine Ark's chat-completions API.
public struct VolcengineArkProvider: LLMProvider {
    public static let defaultBaseURL = AIKitProviderDefaults.arkBaseURL
    public static let defaultChatCompletionsPath = AIKitProviderDefaults.arkChatCompletionsPath

    public var providerName: String { AIKitProviderKind.ark.definition.displayName }

    public let configuration: LLMProviderConfiguration
    public let chatCompletionsPath: String

    public init(
        configuration: LLMProviderConfiguration,
        chatCompletionsPath: String = Self.defaultChatCompletionsPath
    ) {
        self.configuration = configuration
        self.chatCompletionsPath = chatCompletionsPath
    }

    public init(
        apiKey: String,
        model: String? = nil,
        availableModels: [String] = [],
        baseURL: URL = Self.defaultBaseURL,
        chatCompletionsPath: String = Self.defaultChatCompletionsPath,
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
        ), chatCompletionsPath: chatCompletionsPath)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        do {
            let executor = try makeExecutor(for: request)
            let response = try await executor.complete(try arkRequest(from: request))
            return try response.llmResponse
        } catch let error as LLMError {
            throw error
        } catch let error as VolcengineArkError {
            throw error.llmError
        } catch {
            throw LLMError.from(transport: error)
        }
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let executor = try makeExecutor(for: request)
                    for try await event in executor.stream(try arkRequest(from: request)) {
                        for chunk in try event.llmChunks {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch let error as VolcengineArkError {
                    continuation.finish(throwing: error.llmError)
                } catch {
                    continuation.finish(throwing: LLMError.from(transport: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeExecutor(for request: LLMRequest) throws -> VolcengineArkLanguageModelExecutor {
        try VolcengineArkLanguageModelExecutor(
            configuration: .init(
                apiKey: configuration.apiKey,
                model: request.model,
                baseURL: configuration.baseURL,
                chatCompletionsPath: chatCompletionsPath,
                timeout: configuration.timeout
            ),
            session: configuration.session
        )
    }

    private func arkRequest(from request: LLMRequest) throws -> VolcengineArkRequest {
        if request.audioOutput != nil {
            throw LLMError.unsupported("VolcengineArkProvider does not support generated audio output.")
        }
        // Provider wire configuration (thinking, reasoning effort, …) is owned
        // by the VolcengineArkFoundationModels package via its configuration's
        // `defaultExtraBody`; the only request-derived body extension is the
        // guided-generation schema, mapped to a `response_format` constraint.
        var extraBody: [String: VolcengineArkJSONValue] = [:]
        if let schema = request.responseSchema {
            extraBody["response_format"] = try VolcengineArkJSONValue.responseFormat(for: schema)
        }
        return VolcengineArkRequest(
            model: request.model,
            messages: try arkMessages(from: request),
            tools: try request.tools.map(VolcengineArkToolDefinition.init),
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            extraBody: extraBody
        )
    }

    private func arkMessages(from request: LLMRequest) throws -> [VolcengineArkChatMessage] {
        var messages: [VolcengineArkChatMessage] = []
        if let system = request.system?.trimmedNonEmpty {
            messages.append(.init(role: .system, text: system))
        }
        for message in request.messages {
            switch message.role {
            case .system:
                try requireNoUnsupportedMedia(message, role: "system")
                messages.append(.init(role: .system, text: message.plainText))
            case .user:
                messages.append(.init(
                    role: .user,
                    content: try VolcengineArkMessageContent(message: message)
                ))
            case .assistant:
                messages.append(.init(
                    role: .assistant,
                    content: message.plainText.trimmedNonEmpty.map(VolcengineArkMessageContent.text),
                    toolCalls: try message.content.compactMap { block in
                        guard case .toolUse(let id, let name, let arguments) = block else { return nil }
                        return VolcengineArkToolCall(
                            id: id,
                            name: name,
                            arguments: try VolcengineArkJSONValue(arguments)
                        )
                    }
                ))
            case .tool:
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, _) = block {
                        messages.append(.init(
                            role: .tool,
                            content: .text(content),
                            toolCallID: toolUseID
                        ))
                    }
                }
            }
        }
        return messages
    }

    private func requireNoUnsupportedMedia(_ message: Message, role: String) throws {
        guard message.images.isEmpty, message.audio.isEmpty else {
            throw LLMError.unsupported("Volcengine Ark \(role) messages support text only.")
        }
    }
}

private extension VolcengineArkMessageContent {
    init(message: Message) throws {
        var parts: [VolcengineArkContentPart] = []
        var hasMedia = false
        for block in message.content {
            switch block {
            case .text(let text):
                parts.append(.text(text))
            case .reasoning:
                continue
            case .image(let image):
                parts.append(.imageURL(image.arkURL, detail: image.detail?.rawValue))
                hasMedia = true
            case .audio:
                throw LLMError.unsupported("VolcengineArkProvider does not support audio input blocks.")
            case .toolUse, .toolResult:
                continue
            }
        }
        self = hasMedia ? .parts(parts) : .text(message.plainText)
    }
}

private extension ImageContent {
    var arkURL: String {
        switch source {
        case .url(let url):
            url.absoluteString
        case .data(let mimeType, let data):
            "data:\(mimeType);base64,\(data.base64EncodedString())"
        }
    }
}

private extension VolcengineArkToolDefinition {
    init(_ descriptor: ToolDescriptor) throws {
        self.init(
            name: descriptor.name,
            description: descriptor.description,
            parameters: try VolcengineArkJSONValue(descriptor.argumentsSchema)
        )
    }
}

private extension VolcengineArkJSONValue {
    private static let malformedToolInputRawKey = "__volcengine_ark_malformed_tool_input_raw"

    init(_ schema: GenerationSchema) throws {
        self = try VolcengineArkJSONValue(data: Data(schema.jsonString().utf8))
    }

    init(_ content: GeneratedContent) throws {
        self = try VolcengineArkJSONValue(data: content.data())
    }

    var generatedContent: GeneratedContent {
        get throws {
            let content = try GeneratedContent(data: data())
            guard case .structure(let object, _) = content.kind,
                  object.count == 1,
                  case .string(let raw)? = object[Self.malformedToolInputRawKey]?.kind
            else { return content }
            return AIKitMalformedToolInput.make(raw: raw)
        }
    }
}

private extension VolcengineArkResponse {
    var llmResponse: LLMResponse {
        get throws {
            LLMResponse(
                content: try content.map { try $0.contentBlock },
                stopReason: stopReason.llmStopReason,
                usage: TokenUsage(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens
                )
            )
        }
    }
}

private extension VolcengineArkContentBlock {
    var contentBlock: ContentBlock {
        get throws {
            switch self {
            case .text(let text):
                .text(text)
            case .reasoning(let text):
                .reasoning(text)
            case .toolUse(let id, let name, let arguments):
                .toolUse(id: id, name: name, arguments: try arguments.generatedContent)
            }
        }
    }
}

private extension VolcengineArkStreamEvent {
    var llmChunks: [LLMResponseChunk] {
        get throws {
            switch self {
            case .textDelta(let text):
                [.textDelta(text)]
            case .reasoningDelta(let text):
                [.reasoningDelta(text)]
            case .toolUseStart(let id, let name):
                [.toolUseStart(id: id, name: name)]
            case .toolUseInputDelta(let id, let json):
                [.toolUseInputDelta(id: id, json: json)]
            case .toolUseStop(let id):
                [.toolUseStop(id: id)]
            case .stop(let reason):
                [.stop(reason.llmStopReason)]
            case .usage(let usage):
                [.usage(TokenUsage(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens
                ))]
            }
        }
    }
}

private extension VolcengineArkStopReason {
    var llmStopReason: StopReason {
        switch self {
        case .endTurn:
            .endTurn
        case .toolUse:
            .toolUse
        case .maxTokens:
            .maxTokens
        case .other(let value):
            .other(value)
        }
    }
}

private extension VolcengineArkError {
    var llmError: LLMError {
        switch self {
        case .httpStatus(let code, let body):
            .httpStatus(code: code, body: body)
        case .decodingFailed(let detail):
            .decodingFailed(detail)
        case .encodingFailed(let detail):
            .encodingFailed(detail)
        case .missingAPIKey:
            .missingAPIKey
        case .missingModel:
            .missingModel
        case .transport(let detail):
            .transport(detail)
        case .timeout(let detail):
            .timeout(detail)
        case .cancelled:
            .cancelled
        case .unsupported(let detail):
            .unsupported(detail)
        case .provider(let message):
            .provider(message: message)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
