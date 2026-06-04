import Foundation

public enum AIKitProviderKind: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case ollama = "Ollama"
    case appleIntelligence = "Apple Intelligence"
    case ark = "Ark"

    public var id: String { rawValue }

    public init?(providerName: String) {
        switch providerName.normalizedProviderName {
        case "openai":
            self = .openAI
        case "anthropic", "claude":
            self = .anthropic
        case "ollama":
            self = .ollama
        case "appleintelligence", "applefoundationmodels", "foundationmodels", "foundationmodel":
            self = .appleIntelligence
        case "ark", "volcengine", "volcengineark", "doubao":
            self = .ark
        default:
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let provider = Self(providerName: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AIKit provider: \(rawValue)"
            )
        }
        self = provider
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AIKitProviderDefinition: Sendable, Hashable, Identifiable {
    public enum APIKeyStrategy: Sendable, Hashable {
        case none
        case bearerToken
        case anthropicAPIKey
    }

    public enum ModelListFormat: Sendable, Hashable {
        case openAICompatible
        case anthropic
        case ollama
        case staticList([String])
    }

    public enum StreamingProtocol: Sendable, Hashable {
        case openAIChatCompletions
        case anthropicMessages
        case ollamaChat
        case foundationModels
    }

    public let kind: AIKitProviderKind
    public let displayName: String
    public let apiKeyStrategy: APIKeyStrategy
    public let modelListURL: URL
    public let streamingEndpoint: URL
    public let modelListFormat: ModelListFormat
    public let streamingProtocol: StreamingProtocol
    public let allowsStreamingEndpointOverride: Bool
    public let supportsModelCatalogRefresh: Bool
    public let streamingEndpointDisplayName: String?

    public var id: AIKitProviderKind { kind }
    public var staticModelIDs: [String] {
        switch modelListFormat {
        case .openAICompatible, .anthropic, .ollama:
            []
        case .staticList(let models):
            models
        }
    }

    public init(
        kind: AIKitProviderKind,
        displayName: String,
        apiKeyStrategy: APIKeyStrategy,
        modelListURL: URL,
        streamingEndpoint: URL,
        modelListFormat: ModelListFormat,
        streamingProtocol: StreamingProtocol,
        allowsStreamingEndpointOverride: Bool = false,
        supportsModelCatalogRefresh: Bool = true,
        streamingEndpointDisplayName: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.apiKeyStrategy = apiKeyStrategy
        self.modelListURL = modelListURL
        self.streamingEndpoint = streamingEndpoint
        self.modelListFormat = modelListFormat
        self.streamingProtocol = streamingProtocol
        self.allowsStreamingEndpointOverride = allowsStreamingEndpointOverride
        self.supportsModelCatalogRefresh = supportsModelCatalogRefresh
        self.streamingEndpointDisplayName = streamingEndpointDisplayName
    }

    public static let openAI = AIKitProviderDefinition(
        kind: .openAI,
        displayName: "OpenAI",
        apiKeyStrategy: .bearerToken,
        modelListURL: URL(string: "https://api.openai.com/v1/models")!,
        streamingEndpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        modelListFormat: .openAICompatible,
        streamingProtocol: .openAIChatCompletions
    )

    public static let anthropic = AIKitProviderDefinition(
        kind: .anthropic,
        displayName: "Anthropic",
        apiKeyStrategy: .anthropicAPIKey,
        modelListURL: URL(string: "https://api.anthropic.com/v1/models")!,
        streamingEndpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        modelListFormat: .anthropic,
        streamingProtocol: .anthropicMessages
    )

    public static let ollama = AIKitProviderDefinition(
        kind: .ollama,
        displayName: "Ollama",
        apiKeyStrategy: .none,
        modelListURL: URL(string: "http://localhost:11434/api/tags")!,
        streamingEndpoint: URL(string: "http://localhost:11434/api/chat")!,
        modelListFormat: .ollama,
        streamingProtocol: .ollamaChat,
        allowsStreamingEndpointOverride: true
    )

    public static let appleIntelligence = AIKitProviderDefinition(
        kind: .appleIntelligence,
        displayName: "Apple Intelligence",
        apiKeyStrategy: .none,
        modelListURL: URL(string: "aikit-apple-intelligence://local/models")!,
        streamingEndpoint: URL(string: "aikit-apple-intelligence://local")!,
        modelListFormat: .staticList(["apple-intelligence"]),
        streamingProtocol: .foundationModels,
        supportsModelCatalogRefresh: false,
        streamingEndpointDisplayName: "On-device"
    )

    public static let ark = AIKitProviderDefinition(
        kind: .ark,
        displayName: "Volcengine Ark",
        apiKeyStrategy: .bearerToken,
        modelListURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3/models")!,
        streamingEndpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!,
        modelListFormat: .openAICompatible,
        streamingProtocol: .openAIChatCompletions
    )

    public static let all: [AIKitProviderDefinition] = [
        .openAI,
        .anthropic,
        .ollama,
        .appleIntelligence,
        .ark,
    ]
}

public extension AIKitProviderKind {
    var definition: AIKitProviderDefinition {
        switch self {
        case .openAI:
            .openAI
        case .anthropic:
            .anthropic
        case .ollama:
            .ollama
        case .appleIntelligence:
            .appleIntelligence
        case .ark:
            .ark
        }
    }
}

public struct AIKitModelCatalog: Sendable {
    private struct ListedModels: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private struct OllamaTags: Decodable {
        struct Model: Decodable {
            let name: String?
            let model: String?
        }

        let models: [Model]
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchModels(
        for provider: AIKitProviderKind,
        apiKey: String = "",
        timeout: TimeInterval? = nil
    ) async throws -> [String] {
        if case .staticList(let models) = provider.definition.modelListFormat {
            return AIKitModelListNormalizer.uniqueSorted(models)
        }

        let request = try makeRequest(
            provider: provider,
            apiKey: apiKey,
            timeout: timeout
        )
        let data = try await validatedProviderData(for: request, session: session)
        do {
            return try decodeModels(provider: provider, data: data)
        } catch {
            throw LLMError.decodingFailed(String(describing: error))
        }
    }

    private func makeRequest(
        provider: AIKitProviderKind,
        apiKey: String,
        timeout: TimeInterval?
    ) throws -> URLRequest {
        var request = URLRequest(url: provider.definition.modelListURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout {
            request.timeoutInterval = timeout
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider.definition.apiKeyStrategy {
        case .bearerToken:
            guard !trimmedKey.isEmpty else { throw LLMError.missingAPIKey }
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        case .anthropicAPIKey:
            guard !trimmedKey.isEmpty else { throw LLMError.missingAPIKey }
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .none:
            break
        }

        return request
    }

    private func decodeModels(provider: AIKitProviderKind, data: Data) throws -> [String] {
        switch provider.definition.modelListFormat {
        case .openAICompatible, .anthropic:
            let response = try JSONDecoder().decode(ListedModels.self, from: data)
            return AIKitModelListNormalizer.uniqueSorted(response.data.map(\.id))
        case .ollama:
            let response = try JSONDecoder().decode(OllamaTags.self, from: data)
            return AIKitModelListNormalizer.uniqueSorted(response.models.compactMap { $0.name ?? $0.model })
        case .staticList(let models):
            return AIKitModelListNormalizer.uniqueSorted(models)
        }
    }
}

private extension String {
    var normalizedProviderName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
