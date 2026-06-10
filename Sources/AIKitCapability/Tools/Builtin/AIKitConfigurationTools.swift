import Foundation
import FoundationModels
import AIToolKit
import AIKitCore

/// Built-in tool: reads the shared AIKit configuration state.
public struct GetAIKitConfigurationTool: Tool {
    @Generable
    public struct Input: Codable, Sendable {
        public var includeRecentChanges: Bool?

        public init(includeRecentChanges: Bool? = nil) {
            self.includeRecentChanges = includeRecentChanges
        }
    }

    @Generable
    public struct Output: Sendable {
        public var configuration: GeneratedContent
        public var recentChanges: GeneratedContent

        public init(
            configuration: GeneratedContent,
            recentChanges: GeneratedContent
        ) {
            self.configuration = configuration
            self.recentChanges = recentChanges
        }
    }

    public static let toolName = "getAIKitConfiguration"
    public static let toolDescription = """
    Read AIKit's current Core, Capability, Runtime, and Safety configuration.
    """
    public var name: String { Self.toolName }
    public var description: String { Self.toolDescription }

    private let store: AIKitConfigurationStore

    public init(store: AIKitConfigurationStore) {
        self.store = store
    }

    public func call(arguments input: Input) async throws -> Output {
        let changes = await store.recentChanges(
            limit: input.includeRecentChanges == false ? 0 : 10
        )
        return Output(
            configuration: try Self.content(from: await store.snapshot()),
            recentChanges: try Self.content(from: changes)
        )
    }

    private static func content(from value: some Encodable) throws -> GeneratedContent {
        try GeneratedContent(data: JSONEncoder().encode(value))
    }
}

/// Built-in tool: mutates one field in the shared AIKit configuration state.
public struct SetAIKitConfigurationTool: Tool {
    @Generable
    public struct Input: Sendable {
        @Guide(description: "Configuration section: core, capability, runtime, or safety")
        public var section: String
        @Guide(description: "Field name inside the section")
        public var key: String
        @Guide(description: "New JSON value for the field")
        public var value: GeneratedContent

        public init(
            section: String,
            key: String,
            value: GeneratedContent
        ) {
            self.section = section
            self.key = key
            self.value = value
        }

        public init(
            section: AIKitConfiguration.Section,
            key: String,
            value: GeneratedContent
        ) {
            self.init(section: section.rawValue, key: key, value: value)
        }
    }

    @Generable
    public struct Output: Sendable {
        public var applied: Bool
        public var configuration: GeneratedContent
        public var change: GeneratedContent

        public init(
            applied: Bool,
            configuration: GeneratedContent,
            change: GeneratedContent
        ) {
            self.applied = applied
            self.configuration = configuration
            self.change = change
        }
    }

    public static let toolName = "setAIKitConfiguration"
    public static let toolDescription = """
    Change one AIKit configuration field. Sections are core, capability, \
    runtime, and safety. Useful keys include model, activeProvider (Volcengine \
    Ark or Apple Intelligence), availableModels, \
    endpointURL, enabledToolNames, systemPromptFragment, maxIterations, \
    streamsResponses, toolCallFallback, workflowPlanning, twoRoundAutoBind, \
    twoRoundStructuredPlannerOutput, enabledGuardrailIDs, and \
    outputLengthLimit.
    """
    public var name: String { Self.toolName }
    public var description: String { Self.toolDescription }

    private let store: AIKitConfigurationStore
    private let source: String

    public init(store: AIKitConfigurationStore, source: String = "llm") {
        self.store = store
        self.source = source
    }

    public func call(arguments input: Input) async throws -> Output {
        guard let section = AIKitConfiguration.Section(rawValue: input.section) else {
            throw AIKitConfigurationError.invalidValue(
                section: .core,
                key: "section",
                expected: AIKitConfiguration.Section.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        let change = try await store.set(
            section: section,
            key: input.key,
            value: input.value,
            source: source
        )
        let snapshot = await store.snapshot()
        return Output(
            applied: true,
            configuration: try Self.content(from: snapshot),
            change: try Self.content(from: change)
        )
    }

    private static func content(from value: some Encodable) throws -> GeneratedContent {
        try GeneratedContent(data: JSONEncoder().encode(value))
    }
}

/// The configuration tools shipped with AIKit.
public enum AIKitConfigurationTools {
    public static let toolNames: Set<String> = [
        GetAIKitConfigurationTool.toolName,
        SetAIKitConfigurationTool.toolName,
    ]

    /// Both configuration tools, in the `[any Tool]` currency a
    /// `LanguageModelSession` (or the `Orchestrator`) takes.
    public static func all(store: AIKitConfigurationStore) -> [any Tool] {
        [
            GetAIKitConfigurationTool(store: store),
            SetAIKitConfigurationTool(store: store),
        ]
    }
}
