import Foundation

/// Per-provider API keys persisted in `UserDefaults`. This is the single
/// source of truth shared by `AIKitView` (which edits the keys) and host
/// apps (which read them when wiring a provider) — both must go through
/// this type so the storage format stays an implementation detail.
public struct AIKitProviderCredentialStore: Equatable, Sendable {
    private static let storageKey = "AIKitProviderAPIKeys"

    private var apiKeys: [AIKitProviderKind: String]

    public init(apiKeys: [AIKitProviderKind: String] = [:]) {
        self.apiKeys = apiKeys
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let storedValues = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return Self()
        }

        let apiKeys = storedValues.reduce(into: [AIKitProviderKind: String]()) { result, pair in
            guard let provider = AIKitProviderKind(providerName: pair.key),
                  provider.definition.apiKeyStrategy.requiresCredential,
                  !pair.value.isEmpty
            else { return }
            result[provider] = pair.value
        }
        return Self(apiKeys: apiKeys)
    }

    public func apiKey(for provider: AIKitProviderKind) -> String {
        guard provider.definition.apiKeyStrategy.requiresCredential else { return "" }
        return apiKeys[provider] ?? ""
    }

    public mutating func setAPIKey(_ apiKey: String, for provider: AIKitProviderKind) {
        guard provider.definition.apiKeyStrategy.requiresCredential else {
            apiKeys[provider] = nil
            return
        }
        if apiKey.isEmpty {
            apiKeys[provider] = nil
        } else {
            apiKeys[provider] = apiKey
        }
    }

    public func save(defaults: UserDefaults = .standard) {
        let storedValues = apiKeys.reduce(into: [String: String]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        guard let data = try? JSONEncoder().encode(storedValues) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

public extension AIKitProviderDefinition.APIKeyStrategy {
    var requiresCredential: Bool {
        self != .none
    }
}
