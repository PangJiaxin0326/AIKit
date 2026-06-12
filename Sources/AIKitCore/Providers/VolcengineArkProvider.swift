import Foundation
import FoundationModels
import AIToolKit
import VolcengineArkFoundationModels

/// `LLMProvider` backed by Volcengine Ark's chat-completions API.
///
/// A thin shim over `LanguageModelProvider`: requests are driven through
/// `VolcengineArkLanguageModel`'s official Foundation Models conformance, so
/// AIKit's loop and `LanguageModelSession` consumers share the one wire
/// mapping that lives in the Ark package's executor.
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

    public var supportsNativeTools: Bool { adapter.supportsNativeTools }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await adapter.complete(request)
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        adapter.stream(request)
    }

    private var adapter: LanguageModelProvider<VolcengineArkLanguageModel> {
        let configuration = configuration
        let chatCompletionsPath = chatCompletionsPath
        return LanguageModelProvider(
            configuration: configuration,
            providerName: providerName,
            makeModel: { requestedModel in
                VolcengineArkLanguageModel(configuration: .init(
                    apiKey: configuration.apiKey,
                    model: requestedModel.trimmedNonEmpty
                        ?? configuration.defaultModel
                        ?? "",
                    baseURL: configuration.baseURL,
                    chatCompletionsPath: chatCompletionsPath,
                    timeout: configuration.timeout
                ))
            },
            // The official `init(configuration:)` always resolves to
            // `URLSession.shared`; routing construction through the
            // session-taking initializer keeps the host's session (and the
            // tests' URLProtocol stub) in effect.
            makeExecutor: { model in
                try VolcengineArkLanguageModelExecutor(
                    configuration: model.configuration,
                    session: configuration.session
                )
            },
            mapError: { error in (error as? VolcengineArkError)?.llmError }
        )
    }
}

private extension VolcengineArkError {
    var llmError: LLMError {
        switch self {
        case .httpStatus(let code, let body):
            .httpStatus(code: code, body: body)
        case .encodingFailed(let detail):
            .encodingFailed(detail)
        case .missingAPIKey:
            .missingAPIKey
        case .transport(let detail):
            .transport(detail)
        case .unsupported(let detail):
            .unsupported(detail)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
