import Foundation

public enum AIKitProviderKind: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case ark = "Ark"

    public var id: String { rawValue }

    public init?(providerName: String) {
        switch providerName.normalizedProviderName {
        case "ark", "volcengineark":
            self = .ark
        case "appleintelligence":
            self = .appleIntelligence
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
    }

    public enum ModelListFormat: Sendable, Hashable {
        case dataArray
        case staticList([String])
    }

    public enum StreamingProtocol: Sendable, Hashable {
        case chatCompletions
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
        case .dataArray:
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

    public static let appleIntelligence = AIKitProviderDefinition(
        kind: .appleIntelligence,
        displayName: "Apple Intelligence",
        apiKeyStrategy: .none,
        modelListURL: AIKitProviderDefaults.appleIntelligenceModelListURL,
        streamingEndpoint: AIKitProviderDefaults.appleIntelligenceBaseURL,
        modelListFormat: .staticList(["apple-intelligence", "private-cloud-compute"]),
        streamingProtocol: .foundationModels,
        supportsModelCatalogRefresh: false,
        streamingEndpointDisplayName: "On-device / Private Cloud Compute"
    )

    public static let ark = AIKitProviderDefinition(
        kind: .ark,
        displayName: "Volcengine Ark",
        apiKeyStrategy: .bearerToken,
        modelListURL: AIKitProviderDefaults.arkModelListURL,
        streamingEndpoint: AIKitProviderDefaults.arkChatCompletionsURL,
        modelListFormat: .dataArray,
        streamingProtocol: .chatCompletions
    )

    public static let all: [AIKitProviderDefinition] = [
        .ark,
        .appleIntelligence,
    ]
}

public extension AIKitProviderKind {
    var definition: AIKitProviderDefinition {
        switch self {
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
        case .none:
            break
        }

        return request
    }

    private func decodeModels(provider: AIKitProviderKind, data: Data) throws -> [String] {
        switch provider.definition.modelListFormat {
        case .dataArray:
            let response = try JSONDecoder().decode(ListedModels.self, from: data)
            return AIKitModelListNormalizer.uniqueSorted(response.data.map(\.id))
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
