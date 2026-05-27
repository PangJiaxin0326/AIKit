import Foundation
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

    public enum ToolCallFallbackMode: String, CaseIterable, Codable, Sendable, Hashable {
        case automatic
        case enabled
        case disabled
    }

    public struct Core: Codable, Sendable, Hashable {
        public struct ProviderConfiguration: Codable, Sendable, Hashable {
            public var defaultModel: String?
            public var availableModels: [String]
            public var endpointURL: String?

            public init(
                defaultModel: String? = nil,
                availableModels: [String] = [],
                endpointURL: String? = nil,
                baseURL: String? = nil
            ) {
                self.defaultModel = defaultModel?.emptyAsNil
                self.availableModels = Self.normalizedModels(availableModels)
                self.endpointURL = (endpointURL ?? baseURL)?.emptyAsNil
            }

            private enum CodingKeys: String, CodingKey {
                case defaultModel
                case availableModels
                case endpointURL
                case baseURL
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.defaultModel = try container.decodeIfPresent(
                    String.self,
                    forKey: .defaultModel
                )?.emptyAsNil
                self.availableModels = Self.normalizedModels(try container.decodeIfPresent(
                    [String].self,
                    forKey: .availableModels
                ) ?? [])
                let endpointURL = try container.decodeIfPresent(
                    String.self,
                    forKey: .endpointURL
                )?.emptyAsNil
                let legacyBaseURL = try container.decodeIfPresent(
                    String.self,
                    forKey: .baseURL
                )?.emptyAsNil
                self.endpointURL = endpointURL ?? legacyBaseURL
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(defaultModel, forKey: .defaultModel)
                try container.encode(availableModels, forKey: .availableModels)
                try container.encodeIfPresent(endpointURL, forKey: .endpointURL)
            }

            public var baseURL: String? {
                get { endpointURL }
                set { endpointURL = newValue?.emptyAsNil }
            }

            public mutating func replaceAvailableModels(_ models: [String]) {
                let normalized = Self.normalizedModels(models)
                availableModels = normalized
                guard let defaultModel, normalized.contains(defaultModel) else {
                    self.defaultModel = nil
                    return
                }
            }

            private static func normalizedModels(_ models: [String]) -> [String] {
                var seen: Set<String> = []
                var normalized: [String] = []
                for model in models {
                    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                    normalized.append(trimmed)
                }
                return normalized
            }
        }

        public var activeProvider: AIKitProviderKind
        public var openAI: ProviderConfiguration
        public var anthropic: ProviderConfiguration
        public var ollama: ProviderConfiguration
        public var appleIntelligence: ProviderConfiguration
        public var ark: ProviderConfiguration
        public var timeout: TimeInterval?
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            activeProvider: AIKitProviderKind = .ollama,
            openAI: ProviderConfiguration = ProviderConfiguration(),
            anthropic: ProviderConfiguration = ProviderConfiguration(),
            ollama: ProviderConfiguration = ProviderConfiguration(),
            appleIntelligence: ProviderConfiguration = ProviderConfiguration(),
            ark: ProviderConfiguration = ProviderConfiguration(),
            other: ProviderConfiguration? = nil,
            timeout: TimeInterval? = nil,
            temperature: Double? = nil,
            maxTokens: Int? = nil
        ) {
            self.activeProvider = activeProvider
            self.openAI = openAI
            self.anthropic = anthropic
            self.ollama = ollama
            self.appleIntelligence = appleIntelligence
            self.ark = other ?? ark
            self.timeout = timeout
            self.temperature = temperature
            self.maxTokens = maxTokens
        }

        private enum CodingKeys: String, CodingKey {
            case activeProvider
            case openAI
            case anthropic
            case ollama
            case appleIntelligence
            case ark
            case other
            case timeout
            case temperature
            case maxTokens
            case providerName
            case model
            case endpointURL
            case baseURL
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacyProviderName = try container.decodeIfPresent(
                String.self,
                forKey: .providerName
            )
            let decodedActiveProvider = try container.decodeIfPresent(
                AIKitProviderKind.self,
                forKey: .activeProvider
            )
            let activeProvider = decodedActiveProvider
                ?? legacyProviderName.flatMap(AIKitProviderKind.init(providerName:))
                ?? .ollama

            self.activeProvider = activeProvider
            self.openAI = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .openAI
            ) ?? ProviderConfiguration()
            self.anthropic = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .anthropic
            ) ?? ProviderConfiguration()
            self.ollama = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .ollama
            ) ?? ProviderConfiguration()
            self.appleIntelligence = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .appleIntelligence
            ) ?? ProviderConfiguration()
            self.ark = try container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .ark
            ) ?? container.decodeIfPresent(
                ProviderConfiguration.self,
                forKey: .other
            ) ?? ProviderConfiguration()
            self.timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout)
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)

            if container.contains(.model) ||
                container.contains(.endpointURL) ||
                container.contains(.baseURL) {
                var legacyConfiguration = providerConfiguration(for: activeProvider)
                legacyConfiguration.defaultModel = try container.decodeIfPresent(
                    String.self,
                    forKey: .model
                )?.emptyAsNil
                let endpointURL = try container.decodeIfPresent(
                    String.self,
                    forKey: .endpointURL
                )?.emptyAsNil
                let legacyBaseURL = try container.decodeIfPresent(
                    String.self,
                    forKey: .baseURL
                )?.emptyAsNil
                legacyConfiguration.endpointURL = endpointURL ?? legacyBaseURL
                setProviderConfiguration(legacyConfiguration, for: activeProvider)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(activeProvider, forKey: .activeProvider)
            try container.encode(openAI, forKey: .openAI)
            try container.encode(anthropic, forKey: .anthropic)
            try container.encode(ollama, forKey: .ollama)
            try container.encode(appleIntelligence, forKey: .appleIntelligence)
            try container.encode(ark, forKey: .ark)
            try container.encodeIfPresent(timeout, forKey: .timeout)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        }

        public var providerName: String {
            get { activeProvider.rawValue }
            set {
                activeProvider = AIKitProviderKind(providerName: newValue) ?? .ark
            }
        }

        public var model: String? {
            get { activeProviderConfiguration.defaultModel }
            set {
                var providerConfiguration = activeProviderConfiguration
                providerConfiguration.defaultModel = newValue?.emptyAsNil
                setProviderConfiguration(providerConfiguration, for: activeProvider)
            }
        }

        public var endpointURL: String? {
            get { activeProviderConfiguration.endpointURL }
            set {
                var providerConfiguration = activeProviderConfiguration
                providerConfiguration.endpointURL = newValue?.emptyAsNil
                setProviderConfiguration(providerConfiguration, for: activeProvider)
            }
        }

        public var baseURL: String? {
            get { endpointURL }
            set { endpointURL = newValue }
        }

        public var other: ProviderConfiguration {
            get { ark }
            set { ark = newValue }
        }

        public var activeProviderConfiguration: ProviderConfiguration {
            get { providerConfiguration(for: activeProvider) }
            set { setProviderConfiguration(newValue, for: activeProvider) }
        }

        public func providerConfiguration(
            for provider: AIKitProviderKind
        ) -> ProviderConfiguration {
            switch provider {
            case .openAI:
                openAI
            case .anthropic:
                anthropic
            case .ollama:
                ollama
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
            case .openAI:
                openAI = providerConfiguration
            case .anthropic:
                anthropic = providerConfiguration
            case .ollama:
                ollama = providerConfiguration
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
        public var memoryLimit: Int

        public init(
            contextDisplayName: String = "Root",
            systemPromptFragment: String = "",
            enabledToolNames: Set<String> = [],
            memoryLimit: Int = 20
        ) {
            self.contextDisplayName = contextDisplayName
            self.systemPromptFragment = systemPromptFragment
            self.enabledToolNames = enabledToolNames
            self.memoryLimit = memoryLimit
        }
    }

    public struct Runtime: Codable, Sendable, Hashable {
        public var streamsResponses: Bool
        public var maxIterations: Int
        public var maxTurnDuration: TimeInterval?
        public var toolCallFallback: ToolCallFallbackMode

        public init(
            streamsResponses: Bool = true,
            maxIterations: Int = 8,
            maxTurnDuration: TimeInterval? = nil,
            toolCallFallback: ToolCallFallbackMode = .automatic
        ) {
            self.streamsResponses = streamsResponses
            self.maxIterations = maxIterations
            self.maxTurnDuration = maxTurnDuration
            self.toolCallFallback = toolCallFallback
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
        value: JSONValue,
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
        value: JSONValue
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
        value: JSONValue
    ) throws {
        switch key {
        case "provider", "providername", "activeprovider":
            core.providerName = try value.string(section: .core, key: originalKey)
        case "model":
            core.model = try value.optionalString(section: .core, key: originalKey)
        case "endpoint", "endpointurl", "llmendpoint", "streamingendpoint", "baseurl":
            core.endpointURL = try value.optionalString(section: .core, key: originalKey)
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
        value: JSONValue
    ) throws {
        switch key {
        case "context", "contextdisplayname", "displayname":
            capability.contextDisplayName = try value.string(section: .capability, key: originalKey)
        case "systemprompt", "systempromptfragment", "promptfragment":
            capability.systemPromptFragment = try value.string(section: .capability, key: originalKey)
        case "tools", "enabledtools", "enabledtoolnames", "toolnames":
            capability.enabledToolNames = try value.stringSet(section: .capability, key: originalKey)
        case "memorylimit":
            capability.memoryLimit = try value.int(section: .capability, key: originalKey)
        default:
            throw AIKitConfigurationError.unknownKey(section: .capability, key: originalKey)
        }
    }

    private mutating func setRuntime(
        key: String,
        originalKey: String,
        value: JSONValue
    ) throws {
        switch key {
        case "stream", "streaming", "streamsresponses":
            runtime.streamsResponses = try value.bool(section: .runtime, key: originalKey)
        case "maxiterations":
            runtime.maxIterations = try value.int(section: .runtime, key: originalKey)
        case "maxduration", "maxturnduration":
            runtime.maxTurnDuration = try value.optionalDouble(section: .runtime, key: originalKey)
        case "toolfallback", "toolcallfallback":
            runtime.toolCallFallback = try value.toolCallFallbackMode(section: .runtime, key: originalKey)
        default:
            throw AIKitConfigurationError.unknownKey(section: .runtime, key: originalKey)
        }
    }

    private mutating func setSafety(
        key: String,
        originalKey: String,
        value: JSONValue
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

private extension JSONValue {
    var configurationDescription: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return String(value)
        case .int(let value):
            return String(value)
        case .number(let value):
            return String(value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.configurationDescription).joined(separator: ", ")
        case .object:
            return "object"
        }
    }

    func string(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> String {
        guard case .string(let value) = self else {
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
        if case .null = self { return nil }
        return try string(section: section, key: key)
    }

    func bool(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Bool {
        guard case .bool(let value) = self else {
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
        if case .null = self { return nil }
        return try int(section: section, key: key)
    }

    func double(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Double {
        switch self {
        case .int(let value):
            return Double(value)
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
        if case .null = self { return nil }
        return try double(section: section, key: key)
    }

    func stringSet(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> Set<String> {
        switch self {
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
        switch self {
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

    func toolCallFallbackMode(
        section: AIKitConfiguration.Section,
        key: String
    ) throws -> AIKitConfiguration.ToolCallFallbackMode {
        if case .bool(let value) = self {
            return value ? .enabled : .disabled
        }
        let raw = try string(section: section, key: key)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case "auto", "automatic":
            return .automatic
        case "enabled", "enable", "on", "true":
            return .enabled
        case "disabled", "disable", "off", "false":
            return .disabled
        default:
            throw AIKitConfigurationError.invalidValue(
                section: section,
                key: key,
                expected: "automatic, enabled, or disabled"
            )
        }
    }
}
