import Foundation
import Security
import Synchronization

/// Persistence boundary for the encoded credential snapshot. Implementations
/// must replace the value atomically or throw, leaving the previous value intact.
public protocol AIKitCredentialStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

public enum AIKitCredentialError: Error, Sendable, LocalizedError {
    case keychainStatus(Int32)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status): "Credential storage failed (Keychain status \(status))."
        case .invalidData: "Stored credentials could not be decoded."
        }
    }
}

/// App-scoped, device-only Keychain storage; keys never enter preferences or logs.
public struct AIKitKeychainCredentialStorage: AIKitCredentialStorage {
    public let service: String
    public let account: String

    public init(
        service: String = "com.aikit.provider-credentials.\(Bundle.main.bundleIdentifier ?? "host")",
        account: String = "providers"
    ) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AIKitCredentialError.keychainStatus(status) }
        guard let data = result as? Data else { throw AIKitCredentialError.invalidData }
        return data
    }

    public func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            // Another writer may have inserted after the update attempt.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw AIKitCredentialError.keychainStatus(status) }
    }
}

/// Isolated in-memory persistence for tests and previews; never accesses Keychain.
public final class AIKitInMemoryCredentialStorage: AIKitCredentialStorage {
    private let data: Mutex<Data?>
    public init(data: Data? = nil) { self.data = Mutex(data) }
    public func read() -> Data? { data.withLock { $0 } }
    public func write(_ value: Data) { data.withLock { $0 = value } }
}

/// A Sendable credential snapshot. Persistence is explicit and throwing.
public struct AIKitProviderCredentialStore: Equatable, Sendable {
    private static let storageKey = "AIKitProviderAPIKeys"
    private var apiKeys: [AIKitProviderKind: String]

    public init(apiKeys: [AIKitProviderKind: String] = [:]) { self.apiKeys = apiKeys }

    /// Migrates legacy preferences only after secure persistence succeeds.
    /// Existing secure values win. A failure retains legacy data for retry.
    public static func load(
        storage: any AIKitCredentialStorage = AIKitKeychainCredentialStorage(),
        migrating defaults: UserDefaults? = .standard
    ) throws -> Self {
        func decode(_ data: Data) throws -> Self {
            guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw AIKitCredentialError.invalidData
            }
            var result = Self()
            for (name, key) in values {
                if let provider = AIKitProviderKind(providerName: name) {
                    result.setAPIKey(key, for: provider)
                }
            }
            return result
        }
        let secure = try storage.read()
        var result = try secure.map(decode) ?? Self()
        if let legacy = defaults?.data(forKey: storageKey) {
            // An existing secure snapshot wins, including deliberate key
            // removal. Migration must not resurrect a cleared credential.
            if secure == nil { result = try decode(legacy) }
            try result.save(storage: storage)
            defaults?.removeObject(forKey: storageKey)
        }
        return result
    }

    public func apiKey(for provider: AIKitProviderKind) -> String {
        guard provider.definition.apiKeyStrategy.requiresCredential else { return "" }
        return apiKeys[provider] ?? ""
    }

    public mutating func setAPIKey(_ apiKey: String, for provider: AIKitProviderKind) {
        guard provider.definition.apiKeyStrategy.requiresCredential, !apiKey.isEmpty else {
            apiKeys[provider] = nil
            return
        }
        apiKeys[provider] = apiKey
    }

    public func save(storage: any AIKitCredentialStorage = AIKitKeychainCredentialStorage()) throws {
        let values = apiKeys.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }
        try storage.write(JSONEncoder().encode(values))
    }
}
