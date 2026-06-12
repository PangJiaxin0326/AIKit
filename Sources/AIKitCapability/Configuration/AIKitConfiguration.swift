import Foundation
import FoundationModels
import AIToolKit
import AIKitCore

/// User-facing configuration for AIKit's four major pieces.
///
/// This type is intentionally descriptive rather than a live wiring object:
/// host apps can bind it to provider/runtime construction, while AIKit's
/// built-in configuration tools can safely mutate the same state through an
/// actor.
public struct AIKitConfiguration: Codable, Sendable, Hashable {
    public enum Section: String, CaseIterable, Codable, Sendable, Hashable {
        case core
        case capability
        case runtime
        case safety
    }

    public struct Core: Codable, Sendable, Hashable {
        public struct ProviderConfiguration: Codable, Sendable, Hashable {
            public var defaultModel: String?
            public var availableModels: [String]
            public var endpointURL: String?

            public init(
                defaultModel: String? = nil,
                availableModels: [String] = [],
                endpointURL: String? = nil
            ) {
                self.defaultModel = defaultModel?.emptyAsNil
                self.availableModels = AIKitModelListNormalizer.uniquePreservingOrder(availableModels)
                self.endpointURL = endpointURL?.emptyAsNil
            }

            private enum CodingKeys: String, CodingKey {
                case defaultModel
                case availableModels
                case endpointURL
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.defaultModel = try container.decodeIfPresent(
                    String.self,
                    forKey: .defaultModel
                )?.emptyAsNil
                self.availableModels = AIKitModelListNormalizer.uniquePreservingOrder(try container.decodeIfPresent(
                    [String].self,
                    forKey: .availableModels
                ) ?? [])
                let endpointURL = try container.decodeIfPresent(
                    String.self,
                    forKey: .endpointURL
                )?.emptyAsNil
                self.endpointURL = endpointURL
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(defaultModel, forKey: .defaultModel)
                try container.encode(availableModels, forKey: .availableModels)
                try container.encodeIfPresent(endpointURL, forKey: .endpointURL)
            }

            /// Replaces the model list, clearing `defaultModel` when the new
            /// list no longer contains it.
            public mutating func replaceAvailableModels(_ models: [String]) {
                let normalized = AIKitModelListNormalizer.uniquePreservingOrder(models)
                availableModels = normalized
                if let defaultModel, !normalized.contains(defaultModel) {
                    self.defaultModel = nil
                }
            }
        }

        public var activeProvider: AIKitProviderKind
        public var appleIntelligence: ProviderConfiguration
        public var ark: ProviderConfiguration
        public var timeout: TimeInterval?
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            activeProvider: AIKitProviderKind = .ark,
            appleIntelligence: ProviderConfiguration = ProviderConfiguration(),
            ark: ProviderConfiguration = ProviderConfiguration(),
            timeout: TimeInterval? = nil,
            temperature: Double? = 0.2,
            maxTokens: Int? = nil
        ) {
            self.activeProvider = activeProvider
            self.appleIntelligence = appleIntelligence
            self.ark = ark
            self.timeout = timeout
            self.temperature = temperature
            self.maxTokens = maxTokens
        }

        private enum CodingKeys: String, CodingKey {
            case activeProvider
            case appleIntelligence
            case ark
            case timeout
            case temperature
            case maxTokens
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let activeProvider = try container.decodeIfPresent(
                AIKitProviderKind.self,
                forKey: .activeProvider
            ) ?? .ark

            self.activeProvider = activeProvider
            self.appleIntelligence = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .appleIntelligence
            ) ?? ProviderConfiguration()
            self.ark = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .ark
            ) ?? ProviderConfiguration()
            self.timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout)
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
            self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(activeProvider, forKey: .activeProvider)
            try container.encode(appleIntelligence, forKey: .appleIntelligence)
            try container.encode(ark, forKey: .ark)
            try container.encodeIfPresent(timeout, forKey: .timeout)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        }

        public var activeProviderConfiguration: ProviderConfiguration {
            get { providerConfiguration(for: activeProvider) }
            set { setProviderConfiguration(newValue, for: activeProvider) }
        }

        public func providerConfiguration(
            for provider: AIKitProviderKind
        ) -> ProviderConfiguration {
            switch provider {
            case .appleIntelligence:
                appleIntelligence
            case .ark:
                ark
            }
        }

        public mutating func setProviderConfiguration(
            _ providerConfiguration: ProviderConfiguration,
            for provider: AIKitProviderKind
        ) {
            switch provider {
            case .appleIntelligence:
                appleIntelligence = providerConfiguration
            case .ark:
                ark = providerConfiguration
            }
        }
    }

    public struct Capability: Codable, Sendable, Hashable {
        public var contextDisplayName: String
        public var systemPromptFragment: String
        public var enabledToolNames: Set<String>

        public init(
            contextDisplayName: String = "Root",
            systemPromptFragment: String = "",
            enabledToolNames: Set<String> = []
        ) {
            self.contextDisplayName = contextDisplayName
            self.systemPromptFragment = systemPromptFragment
            self.enabledToolNames = enabledToolNames
        }
    }

    public struct Runtime: Codable, Sendable, Hashable {
        public var streamsResponses: Bool
        public var maxTurnDuration: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case streamsResponses
            case maxTurnDuration
        }

        public init(
            streamsResponses: Bool = true,
            maxTurnDuration: TimeInterval? = nil
        ) {
            self.streamsResponses = streamsResponses
            self.maxTurnDuration = maxTurnDuration
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.streamsResponses = try container.decodeIfPresent(
                Bool.self,
                forKey: .streamsResponses
            ) ?? true
            self.maxTurnDuration = try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .maxTurnDuration
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(streamsResponses, forKey: .streamsResponses)
            try container.encodeIfPresent(maxTurnDuration, forKey: .maxTurnDuration)
        }
    }

    public struct Safety: Codable, Sendable, Hashable {
        public var enabledGuardrailIDs: Set<String>
        public var allowlistedToolNames: Set<String>
        public var piiRedactionEnabled: Bool
        public var injectionSniffingEnabled: Bool
        public var outputLengthLimit: Int?

        public init(
            enabledGuardrailIDs: Set<String> = [],
            allowlistedToolNames: Set<String> = [],
            piiRedactionEnabled: Bool = true,
            injectionSniffingEnabled: Bool = true,
            outputLengthLimit: Int? = nil
        ) {
            self.enabledGuardrailIDs = enabledGuardrailIDs
            self.allowlistedToolNames = allowlistedToolNames
            self.piiRedactionEnabled = piiRedactionEnabled
            self.injectionSniffingEnabled = injectionSniffingEnabled
            self.outputLengthLimit = outputLengthLimit
        }
    }

    public var core: Core
    public var capability: Capability
    public var runtime: Runtime
    public var safety: Safety

    public init(
        core: Core = Core(),
        capability: Capability = Capability(),
        runtime: Runtime = Runtime(),
        safety: Safety = Safety()
    ) {
        self.core = core
        self.capability = capability
        self.runtime = runtime
        self.safety = safety
    }

    public static let standard = AIKitConfiguration()
}

/// A durable-enough audit entry for configuration changes made by either a
/// host view or an LLM tool call.
public struct AIKitConfigurationChange: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let source: String
    public let section: AIKitConfiguration.Section?
    public let key: String?
    public let valueDescription: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: String,
        section: AIKitConfiguration.Section?,
        key: String?,
        valueDescription: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.section = section
        self.key = key
        self.valueDescription = valueDescription
    }
}

public enum AIKitConfigurationError: ToolError, Sendable, Hashable {
    case unknownKey(section: AIKitConfiguration.Section, key: String)
    case invalidValue(section: AIKitConfiguration.Section, key: String, expected: String)

    public var isRetriable: Bool { false }

    public var message: String {
        switch self {
        case .unknownKey(let section, let key):
            return "Unknown AIKit \(section.rawValue) configuration key '\(key)'."
        case .invalidValue(let section, let key, let expected):
            return "Invalid value for AIKit \(section.rawValue).\(key); expected \(expected)."
        }
    }
}

/// Shared mutable configuration. An actor keeps UI edits and tool-call edits
/// serialized without exposing mutable state across concurrency domains.
public actor AIKitConfigurationStore {
    private var configuration: AIKitConfiguration
    private var changes: [AIKitConfigurationChange]

    public init(configuration: AIKitConfiguration = .standard) {
        self.configuration = configuration
        self.changes = []
    }

    public func snapshot() -> AIKitConfiguration {
        configuration
    }

    @discardableResult
    public func replace(
        with configuration: AIKitConfiguration,
        source: String = "host"
    ) -> AIKitConfigurationChange {
        self.configuration = configuration
        let change = AIKitConfigurationChange(
            source: source,
            section: nil,
            key: nil,
            valueDescription: "Replaced full configuration"
        )
        record(change)
        return change
    }

    @discardableResult
    public func set(
        section: AIKitConfiguration.Section,
        key: String,
        value: GeneratedContent,
        source: String = "host"
    ) throws -> AIKitConfigurationChange {
        try configuration.set(section: section, key: key, value: value)
        let change = AIKitConfigurationChange(
            source: source,
            section: section,
            key: key,
            valueDescription: value.configurationDescription
        )
        record(change)
        return change
    }

    public func recentChanges(limit: Int = 10) -> [AIKitConfigurationChange] {
        Array(changes.suffix(max(0, limit)).reversed())
    }

    private func record(_ change: AIKitConfigurationChange) {
        changes.append(change)
        if changes.count > 100 {
            changes.removeFirst(changes.count - 100)
        }
    }
}

extension AIKitConfiguration {
    public mutating func set(
        section: Section,
        key: String,
        value: GeneratedContent
    ) throws {
        let normalized = key.normalizedConfigurationKey
        switch section {
        case .core:
            try setCore(key: normalized, originalKey: key, value: value)
        case .capability:
            try setCapability(key: normalized, originalKey: key, value: value)
        case .runtime:
            try setRuntime(key: normalized, originalKey: key, value: value)
        case .safety:
            try setSafety(key: normalized, originalKey: key, value: value)
        }
    }

    private mutating func setCore(
        key: String,
        originalKey: String,
        value: GeneratedContent
    ) throws {
        switch key {
        case "provider", "activeprovider":
            let providerName = try value.string(section: .core, key: originalKey)
            guard let provider = AIKitProviderKind(providerName: providerName) else {
                throw AIKitConfigurationError.invalidValue(
                    section: .core,
                    key: originalKey,
                    expected: "Ark or Apple Intelligence"
                )
            }
            core.activeProvider = provider
        case "model":
            var providerConfiguration = core.activeProviderConfiguration
            providerConfiguration.defaultModel = try value
                .optionalString(section: .core, key: originalKey)
            core.activeProviderConfiguration = providerConfiguration
        case "endpoint", "endpointurl", "llmendpoint", "streamingendpoint":
            var providerConfiguration = core.activeProviderConfiguration
            providerConfiguration.endpointURL = try value
                .optionalString(section: .core, key: originalKey)
            core.activeProviderConfiguration = providerConfiguration
        case "models", "availablemodels", "availablemodel":
            var providerConfiguration = core.activeProviderConfiguration
            providerConfiguration.replaceAvailableModels(
                try value.stringArray(section: .core, key: originalKey)
            )
            core.activeProviderConfiguration = providerConfiguration
        case "timeout":
            core.timeout = try value.optionalDouble(section: .core, key: originalKey)
        case "temperature":
            core.temperature = try value.optionalDouble(section: .core, key: originalKey)
        case "maxtokens":
            core.maxTokens = try value.optionalInt(section: .core, key: originalKey)
        default:
            throw AIKitConfigurationError.unknownKey(section: .core, key: originalKey)
        }
    }

    private mutating func setCapability(
        key: String,
        originalKey: String,
        value: GeneratedContent
    ) throws {
        switch key {
        case "context", "contextdisplayname", "displayname":
            capability.contextDisplayName = try value.string(section: .capability, key: originalKey)
        case "systemprompt", "systempromptfragment", "promptfragment":
            capability.systemPromptFragment = try value.string(section: .capability, key: originalKey)
        case "tools", "enabledtools", "enabledtoolnames", "toolnames":
            capability.enabledToolNames = try value.stringSet(section: .capability, key: originalKey)
        default:
            throw AIKitConfigurationError.unknownKey(section: .capability, key: originalKey)
        }
    }

    private mutating func setRuntime(
        key: String,
        originalKey: String,
        value: GeneratedContent
    ) throws {
        switch key {
        case "stream", "streaming", "streamsresponses":
            runtime.streamsResponses = try value.bool(section: .runtime, key: originalKey)
        case "maxduration", "maxturnduration":
            runtime.maxTurnDuration = try value.optionalDouble(section: .runtime, key: originalKey)
        default:
            throw AIKitConfigurationError.unknownKey(section: .runtime, key: originalKey)
        }
    }

    private mutating func setSafety(
        key: String,
        originalKey: String,
        value: GeneratedContent
    ) throws {
        switch key {
        case "guardrails", "enabledguardrails", "enabledguardrailids":
            safety.enabledGuardrailIDs = try value.stringSet(section: .safety, key: originalKey)
        case "allowlist", "allowlistedtools", "allowlistedtoolnames":
            safety.allowlistedToolNames = try value.stringSet(section: .safety, key: originalKey)
        case "pii", "piiredaction", "piiredactionenabled":
            safety.piiRedactionEnabled = try value.bool(section: .safety, key: originalKey)
        case "injection", "injectionsniffing", "injectionsniffingenabled":
            safety.injectionSniffingEnabled = try value.bool(section: .safety, key: originalKey)
        case "outputlength", "outputlimit", "outputlengthlimit":
            safety.outputLengthLimit = try value.optionalInt(section: .safety, key: originalKey)
        default:
            throw AIKitConfigurationError.unknownKey(section: .safety, key: originalKey)
        }
    }
}

private extension String {
    var normalizedConfigurationKey: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var emptyAsNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension GeneratedContent {
    var configurationDescription: String {
        switch kind {
        case .null:
            return "null"
        case .bool(let value):
            return String(value)
        case .number(let value):
            return String(value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.configurationDescription).joined(separator: ", ")
        case .structure:
            return "object"
        @unknown default:
            return jsonString
        }
    }

    func string(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> String {
        guard case .string(let value) = kind else {
            throw AIKitConfigurationError.invalidValue(
                section: section, key: key, expected: "a string"
            )
        }
        return value
    }

    func optionalString(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> String? {
        if case .null = kind { return nil }
        return try string(section: section, key: key)
    }

    func bool(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Bool {
        guard case .bool(let value) = kind else {
            throw AIKitConfigurationError.invalidValue(
                section: section, key: key, expected: "a boolean"
            )
        }
        return value
    }

    func int(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Int {
        if let value = intValue { return value }
        throw AIKitConfigurationError.invalidValue(
            section: section, key: key, expected: "an integer"
        )
    }

    func optionalInt(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Int? {
        if case .null = kind { return nil }
        return try int(section: section, key: key)
    }

    func double(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Double {
        switch kind {
        case .number(let value):
            return value
        default:
            throw AIKitConfigurationError.invalidValue(
                section: section, key: key, expected: "a number"
            )
        }
    }

    func optionalDouble(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Double? {
        if case .null = kind { return nil }
        return try double(section: section, key: key)
    }

    func stringSet(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Set<String> {
        switch kind {
        case .array(let values):
            return Set(try values.map { try $0.string(section: section, key: key) })
        case .string(let value):
            return Set(value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        default:
            throw AIKitConfigurationError.invalidValue(
                section: section, key: key, expected: "an array of strings"
            )
        }
    }

    func stringArray(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> [String] {
        switch kind {
        case .array(let values):
            return try values.map { try $0.string(section: section, key: key) }
        case .string(let value):
            return value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            throw AIKitConfigurationError.invalidValue(
                section: section, key: key, expected: "an array of strings"
            )
        }
    }
}
