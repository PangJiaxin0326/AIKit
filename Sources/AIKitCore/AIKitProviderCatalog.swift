import Foundation

/// The providers AIKit ships models for. Apple Intelligence covers both the
/// on-device system model and Private Cloud Compute; Ark is Volcengine's
/// OpenAI-compatible cloud service, implemented by the
/// `VolcengineArkFoundationModels` package.
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

/// Dashboard metadata for one provider: what the configuration UI needs to
/// render a provider row. Transport lives in the model implementations
/// (`FoundationModels` for Apple, the Ark package for Volcengine), never here.
public struct AIKitProviderDefinition: Sendable, Hashable, Identifiable {
    public enum APIKeyStrategy: Sendable, Hashable {
        case none
        case bearerToken
    }

    public let kind: AIKitProviderKind
    public let displayName: String
    public let apiKeyStrategy: APIKeyStrategy
    /// Fixed model ids for providers without a model-list endpoint.
    public let staticModelIDs: [String]
    /// Whether `AIKitModelCatalog.fetchModels` reaches a live endpoint for
    /// this provider (vs. returning `staticModelIDs`).
    public let supportsModelCatalogRefresh: Bool

    public var id: AIKitProviderKind { kind }

    public init(
        kind: AIKitProviderKind,
        displayName: String,
        apiKeyStrategy: APIKeyStrategy,
        staticModelIDs: [String] = [],
        supportsModelCatalogRefresh: Bool = true
    ) {
        self.kind = kind
        self.displayName = displayName
        self.apiKeyStrategy = apiKeyStrategy
        self.staticModelIDs = staticModelIDs
        self.supportsModelCatalogRefresh = supportsModelCatalogRefresh
    }

    public static let appleIntelligence = AIKitProviderDefinition(
        kind: .appleIntelligence,
        displayName: "Apple Intelligence",
        apiKeyStrategy: .none,
        staticModelIDs: [
            "apple-intelligence",
            "private-cloud-compute",
        ],
        supportsModelCatalogRefresh: false
    )

    public static let ark = AIKitProviderDefinition(
        kind: .ark,
        displayName: "Volcengine Ark",
        apiKeyStrategy: .bearerToken
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

public extension AIKitProviderDefinition.APIKeyStrategy {
    var requiresCredential: Bool {
        self != .none
    }
}

/// Typed errors from the model-list fetch.
public enum AIKitModelCatalogError: Error, Sendable, Hashable {
    case missingAPIKey
    case httpStatus(code: Int, body: String)
    case decodingFailed(String)
    case transport(String)
}

extension AIKitModelCatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "The model list requires an API key."
        case .httpStatus(let code, let body):
            "Model list HTTP \(code): \(body)"
        case .decodingFailed(let detail):
            "Model list decoding failed: \(detail)"
        case .transport(let detail):
            "Model list transport error: \(detail)"
        }
    }
}

/// Optional model-list transport supplied by the host/provider integration.
public protocol AIKitModelCatalogFetching: Sendable {
    func supportsRefresh(for provider: AIKitProviderKind) -> Bool
    func fetchModels(for provider: AIKitProviderKind, apiKey: String, timeout: TimeInterval?) async throws -> [String]
}

extension AIKitModelCatalogFetching {
    public func supportsRefresh(for provider: AIKitProviderKind) -> Bool {
        provider.definition.supportsModelCatalogRefresh
    }
}

/// Offline catalog for Apple-only consumers and previews.
public struct AIKitStaticModelCatalog: AIKitModelCatalogFetching {
    public init() {}
    public func supportsRefresh(for provider: AIKitProviderKind) -> Bool { false }
    public func fetchModels(for provider: AIKitProviderKind, apiKey: String = "", timeout: TimeInterval? = nil) async throws -> [String] {
        provider.definition.staticModelIDs
    }
}

package enum AIKitModelListNormalizer {
    package static func uniquePreservingOrder(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }

    package static func uniqueSorted(_ models: [String]) -> [String] {
        uniquePreservingOrder(models).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}

private extension String {
    var normalizedProviderName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
