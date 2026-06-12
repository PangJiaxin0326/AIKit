import Foundation
import FoundationModels
import VolcengineArkFoundationModels

/// The language models AIKit ships, each wrapped in its official Foundation
/// Models `LanguageModel` conformance: Apple's on-device system model,
/// Private Cloud Compute, and Volcengine Ark (a provider package, as Apple
/// recommends third-party models be distributed).
///
/// AIKitCore adds nothing on top of the official protocol API — this enum
/// only selects and constructs a model value. All generation goes through a
/// `LanguageModelSession` over that value (see `makeSession`), so tool
/// calling, guided generation, streaming, and transcript management are the
/// system implementations.
public enum AIKitLanguageModel: Sendable {
    case appleIntelligence(SystemLanguageModel)
    case privateCloudCompute(PrivateCloudComputeLanguageModel)
    case volcengineArk(VolcengineArkLanguageModel)
}

public extension AIKitLanguageModel {
    /// Stable model ids for the Apple Intelligence endpoints, used by the
    /// dashboard's static model list and by `resolve`.
    static let appleIntelligenceModelID = "apple-intelligence"
    static let privateCloudComputeModelID = "private-cloud-compute"

    /// Apple's on-device system model.
    static var appleIntelligence: Self { .appleIntelligence(.default) }

    /// Apple's Private Cloud Compute model.
    static var privateCloudCompute: Self {
        .privateCloudCompute(PrivateCloudComputeLanguageModel())
    }

    /// A Volcengine Ark model. The host app owns the API key; the package
    /// never reads environment variables.
    static func volcengineArk(
        apiKey: String,
        model: String,
        timeout: TimeInterval? = nil
    ) -> Self {
        .volcengineArk(VolcengineArkLanguageModel(
            apiKey: apiKey,
            model: model,
            timeout: timeout
        ))
    }
}

public extension AIKitLanguageModel {
    /// Unified availability across the three model families.
    enum Availability: Sendable, Equatable {
        case available
        case unavailable(reason: String)
    }

    /// The underlying official model value, type-erased. Hands the model to
    /// API that takes `some LanguageModel` (implicitly opened) or stores
    /// `any LanguageModel`.
    var base: any LanguageModel {
        switch self {
        case .appleIntelligence(let model): model
        case .privateCloudCompute(let model): model
        case .volcengineArk(let model): model
        }
    }

    /// The official capability set declared by the underlying model.
    var capabilities: LanguageModelCapabilities {
        base.capabilities
    }

    /// Which provider this model belongs to, for dashboard metadata and
    /// usage records.
    var providerKind: AIKitProviderKind {
        switch self {
        case .appleIntelligence, .privateCloudCompute: .appleIntelligence
        case .volcengineArk: .ark
        }
    }

    /// The model id as the dashboard and usage records know it.
    var modelID: String {
        switch self {
        case .appleIntelligence: Self.appleIntelligenceModelID
        case .privateCloudCompute: Self.privateCloudComputeModelID
        case .volcengineArk(let model): model.configuration.model
        }
    }

    var availability: Availability {
        switch self {
        case .appleIntelligence(let model):
            switch model.availability {
            case .available:
                .available
            case .unavailable(let reason):
                .unavailable(reason: "Apple Intelligence is unavailable: \(reason)")
            }
        case .privateCloudCompute(let model):
            switch model.availability {
            case .available:
                .available
            case .unavailable(let reason):
                .unavailable(reason: "Private Cloud Compute is unavailable: \(reason)")
            }
        case .volcengineArk(let model):
            if model.configuration.apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                .unavailable(reason: "Volcengine Ark has no API key configured.")
            } else if model.configuration.model
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                .unavailable(reason: "Volcengine Ark has no model selected.")
            } else {
                .available
            }
        }
    }

    var isAvailable: Bool {
        availability == .available
    }
}

// MARK: - Sessions

public extension AIKitLanguageModel {
    /// An official `LanguageModelSession` over this model. The session owns
    /// the loop: it executes `tools` natively, applies guided generation, and
    /// maintains the transcript.
    func makeSession(
        tools: [any Tool] = [],
        instructions: Instructions? = nil
    ) -> LanguageModelSession {
        LanguageModelSession(model: base, tools: tools, instructions: instructions)
    }

    /// An official session resuming a prior transcript.
    func makeSession(
        tools: [any Tool] = [],
        transcript: Transcript
    ) -> LanguageModelSession {
        LanguageModelSession(model: base, tools: tools, transcript: transcript)
    }
}

// MARK: - Resolution from dashboard selection

/// Thrown by `AIKitLanguageModel.resolve` when a dashboard selection cannot
/// become a model value.
public enum AIKitModelResolutionError: Error, Sendable, Hashable {
    /// The provider requires an API key and none is configured.
    case missingAPIKey(AIKitProviderKind)
    /// The provider requires an explicit model id and none is selected.
    case missingModel(AIKitProviderKind)
    /// The model id does not name a known model for the provider.
    case unknownModel(AIKitProviderKind, modelID: String)
}

extension AIKitModelResolutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.definition.displayName) needs an API key."
        case .missingModel(let provider):
            "\(provider.definition.displayName) has no model selected."
        case .unknownModel(let provider, let modelID):
            "\(provider.definition.displayName) has no model \"\(modelID)\"."
        }
    }
}

public extension AIKitLanguageModel {
    /// Builds the model for a dashboard selection: a provider, the selected
    /// model id, and the provider's credential.
    static func resolve(
        provider: AIKitProviderKind,
        modelID: String?,
        apiKey: String = "",
        timeout: TimeInterval? = nil
    ) throws -> AIKitLanguageModel {
        let trimmedModelID = modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .appleIntelligence:
            switch trimmedModelID {
            case nil, "", Self.appleIntelligenceModelID:
                return .appleIntelligence
            case Self.privateCloudComputeModelID:
                return .privateCloudCompute
            case .some(let other):
                throw AIKitModelResolutionError.unknownModel(provider, modelID: other)
            }
        case .ark:
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else {
                throw AIKitModelResolutionError.missingAPIKey(provider)
            }
            guard let model = trimmedModelID, !model.isEmpty else {
                throw AIKitModelResolutionError.missingModel(provider)
            }
            return .volcengineArk(apiKey: trimmedKey, model: model, timeout: timeout)
        }
    }

    /// `resolve` reading the provider's API key from the shared credential
    /// store.
    static func resolve(
        provider: AIKitProviderKind,
        modelID: String?,
        credentials: AIKitProviderCredentialStore,
        timeout: TimeInterval? = nil
    ) throws -> AIKitLanguageModel {
        try resolve(
            provider: provider,
            modelID: modelID,
            apiKey: credentials.apiKey(for: provider),
            timeout: timeout
        )
    }
}
