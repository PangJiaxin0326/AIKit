import Foundation
import AIKitCore

/// Built-in tool: reads the shared AIKit configuration state.
public struct GetAIKitConfigurationTool: Tool {
    public struct Input: Codable, Sendable {
        public var includeRecentChanges: Bool?

        public init(includeRecentChanges: Bool? = nil) {
            self.includeRecentChanges = includeRecentChanges
        }
    }

    public struct Output: Codable, Sendable {
        public var configuration: AIKitConfiguration
        public var recentChanges: [AIKitConfigurationChange]

        public init(
            configuration: AIKitConfiguration,
            recentChanges: [AIKitConfigurationChange]
        ) {
            self.configuration = configuration
            self.recentChanges = recentChanges
        }
    }

    public static let name = "getAIKitConfiguration"
    public static let description = """
    Read AIKit's current Core, Capability, Runtime, and Safety configuration.
    """
    public static let schema = ToolSchema.object(
        properties: [
            "includeRecentChanges": .boolean,
        ]
    )

    private let store: AIKitConfigurationStore

    public init(store: AIKitConfigurationStore) {
        self.store = store
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let changes = await store.recentChanges(
            limit: input.includeRecentChanges == false ? 0 : 10
        )
        return Output(
            configuration: await store.snapshot(),
            recentChanges: changes
        )
    }
}

/// Built-in tool: mutates one field in the shared AIKit configuration state.
public struct SetAIKitConfigurationTool: Tool {
    public struct Input: Codable, Sendable {
        public var section: AIKitConfiguration.Section
        public var key: String
        public var value: JSONValue

        public init(
            section: AIKitConfiguration.Section,
            key: String,
            value: JSONValue
        ) {
            self.section = section
            self.key = key
            self.value = value
        }
    }

    public struct Output: Codable, Sendable {
        public var applied: Bool
        public var configuration: AIKitConfiguration
        public var change: AIKitConfigurationChange

        public init(
            applied: Bool,
            configuration: AIKitConfiguration,
            change: AIKitConfigurationChange
        ) {
            self.applied = applied
            self.configuration = configuration
            self.change = change
        }
    }

    public static let name = "setAIKitConfiguration"
    public static let description = """
    Change one AIKit configuration field. Sections are core, capability, \
    runtime, and safety. Useful keys include model, activeProvider (OpenAI, \
    Anthropic, Ollama, or Other), availableModels, baseURL, enabledToolNames, \
    systemPromptFragment, maxIterations, streamsResponses, toolCallFallback, \
    enabledGuardrailIDs, and outputLengthLimit.
    """
    public static let schema = ToolSchema(json: .object([
        "type": .string("object"),
        "properties": .object([
            "section": .object([
                "type": .string("string"),
                "description": .string("Configuration section"),
                "enum": .array(AIKitConfiguration.Section.allCases.map { .string($0.rawValue) }),
            ]),
            "key": .object([
                "type": .string("string"),
                "description": .string("Field name inside the section"),
            ]),
            "value": .object([
                "description": .string("New JSON value for the field"),
            ]),
        ]),
        "required": .array([
            .string("section"),
            .string("key"),
            .string("value"),
        ]),
    ]))

    private let store: AIKitConfigurationStore

    public init(store: AIKitConfigurationStore) {
        self.store = store
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let change = try await store.set(
            section: input.section,
            key: input.key,
            value: input.value,
            source: "llm:\(context.viewID)"
        )
        return Output(
            applied: true,
            configuration: await store.snapshot(),
            change: change
        )
    }
}

/// Convenience registration for the configuration tools shipped with AIKit.
public enum AIKitConfigurationTools {
    public static let toolNames: Set<String> = [
        GetAIKitConfigurationTool.name,
        SetAIKitConfigurationTool.name,
    ]

    public static func register(
        in registry: ToolRegistry,
        store: AIKitConfigurationStore
    ) async {
        await registry.register(GetAIKitConfigurationTool(store: store))
        await registry.register(SetAIKitConfigurationTool(store: store))
    }
}
