import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import AIKitCapability
import AIKitCore
import AIToolKit

private struct EchoTool: Tool {
    @Generable
    struct Input: Codable, Sendable { var text: String }
    @Generable
    struct Output: Codable, Sendable { var echoed: String }

    let name = "echo"
    let description = "Echoes input back, recording the call in memory."

    let memory: any MemoryStore

    func call(arguments input: Input) async throws -> Output {
        try await memory.append(UsageEvent(
            viewID: ViewContext.ID("tool"),
            kind: .toolInvoked,
            text: "echo:\(input.text)"
        ))
        return Output(echoed: input.text)
    }
}

private func jsonData(_ value: some ConvertibleToGeneratedContent) -> Data {
    Data(value.generatedContent.jsonString.utf8)
}

private func generatedValue<Value: ConvertibleFromGeneratedContent>(
    _ type: Value.Type = Value.self,
    from data: Data
) throws -> Value {
    try Value(GeneratedContent(data: data))
}

@Suite struct ToolRegistryTests {
    @Test func registerInvokeAndMemory() async throws {
        let registry = ToolRegistry()
        let memory = InMemoryMemoryStore()
        await registry.register(EchoTool(memory: memory))
        let context = ToolContext(viewID: "home")

        let input = jsonData(EchoTool.Input(text: "hi"))
        let outData = try await registry.call(
            name: "echo", jsonArguments: input, context: context
        )
        let output = try generatedValue(EchoTool.Output.self, from: outData)
        #expect(output.echoed == "hi")

        let recent = try await memory.recent(limit: 10, view: nil)
        #expect(recent.count == 1)
        #expect(recent.first?.kind == .toolInvoked)
        #expect(recent.first?.payloadText == "echo:hi")
    }

    @Test func manifestSubsetting() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool(memory: InMemoryMemoryStore()))
        await registry.register(SearchMemoryTool(memory: InMemoryMemoryStore()))
        let subset = await registry.manifest(for: ["echo"])
        #expect(subset.map(\.name) == ["echo"])
    }

    @Test func emptyManifestHasNoTools() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool(memory: InMemoryMemoryStore()))
        let manifest = await registry.manifest(for: [])
        #expect(manifest.isEmpty)
    }

    @Test func registeredDescriptorsReturnsAllTools() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool(memory: InMemoryMemoryStore()))
        await registry.register(SearchMemoryTool(memory: InMemoryMemoryStore()))
        let all = await registry.registeredDescriptors()
        #expect(all.map(\.name) == ["echo", "searchMemory"])
    }

    @Test func builtInDescriptorsExposeWorkflowMetadata() {
        let navigate = NavigateTool { _ in .init(navigated: true) }.descriptor
        #expect(navigate.outputSchema != nil)
        #expect(navigate.annotations?.sideEffect == .localWrite)
        #expect(navigate.annotations?.sensitiveOutput == ToolAnnotations.SensitiveOutput.none)
        #expect(navigate.argumentExamples?.isEmpty == false)

        let search = SearchMemoryTool(memory: InMemoryMemoryStore()).descriptor
        #expect(search.outputSchema != nil)
        #expect(search.annotations?.isReadOnly == true)
        #expect(search.annotations?.sensitiveOutput == .privateContent)
    }

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.self) {
            try await registry.call(
                name: "nope",
                jsonArguments: Data("{}".utf8),
                context: ToolContext(viewID: "v")
            )
        }
    }
}

@Suite struct ContextResolverTests {
    @Test func pushPopMerge() async {
        let resolver = ContextResolver()
        _ = await resolver.push(ViewContext(
            id: .init("root"),
            displayName: "Root",
            systemPromptFragment: "You are root.",
            toolNames: ["navigate"]
        ))
        let settings = await resolver.push(ViewContext(
            id: .init("settings"),
            displayName: "Settings",
            systemPromptFragment: "You can change settings.",
            toolNames: ["setSetting"]
        ))
        let merged = await resolver.merged()
        #expect(merged.toolNames == ["navigate", "setSetting"])
        #expect(merged.systemPromptFragment.contains("root"))
        #expect(merged.systemPromptFragment.contains("settings"))
        #expect(merged.leafID == ViewContext.ID("settings"))

        await resolver.pop(settings)
        let after = await resolver.merged()
        #expect(after.toolNames == ["navigate"])
    }

    @Test func tokenPopRemovesExactFrameNotByID() async {
        let resolver = ContextResolver()
        let first = await resolver.push(ViewContext(
            id: .init("dup"), displayName: "First", toolNames: ["a"]
        ))
        await resolver.push(ViewContext(
            id: .init("dup"), displayName: "Second", toolNames: ["b"]
        ))
        // Two live frames share the id; popping the first token must leave the
        // second intact (the id-based pop could not tell them apart).
        await resolver.pop(first)
        let merged = await resolver.merged()
        #expect(merged.toolNames == ["b"])
        #expect(merged.stack == [ViewContext.ID("dup")])
    }

    @Test func doublePopByTokenIsIdempotent() async {
        let resolver = ContextResolver()
        let token = await resolver.push(ViewContext(id: .init("x"), displayName: "X"))
        await resolver.pop(token)
        await resolver.pop(token)
        let current = await resolver.current()
        #expect(current.isEmpty)
    }
}

@Suite(.serialized) struct MemoryStoreTests {
    @Test func inMemoryRecentAndSearch() async throws {
        let store = InMemoryMemoryStore()
        try await store.append(UsageEvent(viewID: .init("a"), kind: .userInstruction, text: "open settings"))
        try await store.append(UsageEvent(viewID: .init("b"), kind: .llmResponse, text: "done"))
        let recent = try await store.recent(limit: 1, view: nil)
        #expect(recent.count == 1)
        let viewScoped = try await store.recent(limit: 10, view: .init("a"))
        #expect(viewScoped.count == 1)
        let found = try await store.search(query: "settings", limit: 10)
        #expect(found.count == 1)
    }

    @Test func inMemoryDeleteForgetsEntry() async throws {
        let store = InMemoryMemoryStore()
        let keep = UsageEvent(viewID: .init("a"), kind: .userInstruction, text: "keep")
        let drop = UsageEvent(viewID: .init("a"), kind: .userInstruction, text: "drop")
        try await store.append(keep)
        try await store.append(drop)
        try await store.delete(id: drop.id)
        let remaining = try await store.recent(limit: 10, view: nil)
        #expect(remaining.map(\.id) == [keep.id])
    }

    @Test func swiftDataRoundTrip() async throws {
        let store = try SwiftDataMemoryStore(path: nil)
        let event = UsageEvent(viewID: .init("home"), kind: .toolResult, text: "result payload")
        try await store.append(event)
        let recent = try await store.recent(limit: 10, view: .init("home"))
        #expect(recent.count == 1)
        #expect(recent.first?.payloadText == "result payload")
        let hits = try await store.search(query: "payload", limit: 5)
        #expect(hits.count == 1)
        let none = try await store.recent(limit: 10, view: .init("other"))
        #expect(none.isEmpty)
    }

    @Test func swiftDataFileBackedStoreOpensWithoutCloudKit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIKitSwiftDataMemoryStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SwiftDataMemoryStore(
            path: root.appendingPathComponent("memory.store").path
        )
        let event = UsageEvent(viewID: .init("home"), kind: .error, text: "recoverable")

        try await store.append(event)

        let recent = try await store.recent(limit: 10, view: .init("home"))
        #expect(recent.map(\.id) == [event.id])
    }

    @Test func swiftDataSearchTreatsQueryLiterally() async throws {
        let store = try SwiftDataMemoryStore(path: nil)
        try await store.append(UsageEvent(
            viewID: .init("a"), kind: .userInstruction, text: "100% sure"
        ))
        try await store.append(UsageEvent(
            viewID: .init("a"), kind: .userInstruction, text: "totally unrelated"
        ))
        // A bare "%" must be matched literally, not as "match everything".
        let percent = try await store.search(query: "%", limit: 10)
        #expect(percent.count == 1)
        #expect(percent.first?.payloadText == "100% sure")
        // "_" likewise literal.
        let underscore = try await store.search(query: "_", limit: 10)
        #expect(underscore.isEmpty)
    }

    @Test func swiftDataStoreDoesNotFetchForNonPositiveLimits() async throws {
        let store = try SwiftDataMemoryStore(path: nil)
        try await store.append(UsageEvent(
            viewID: .init("home"), kind: .toolResult, text: "visible"
        ))

        #expect(try await store.recent(limit: 0, view: nil).isEmpty)
        #expect(try await store.recent(limit: -1, view: nil).isEmpty)
        #expect(try await store.search(query: "visible", limit: 0).isEmpty)
        #expect(try await store.search(query: "visible", limit: -1).isEmpty)
    }

    @Test func swiftDataDeleteForgetsEntry() async throws {
        let store = try SwiftDataMemoryStore(path: nil)
        let keep = UsageEvent(viewID: .init("home"), kind: .toolResult, text: "keep me")
        let drop = UsageEvent(viewID: .init("home"), kind: .toolResult, text: "forget me")
        try await store.append(keep)
        try await store.append(drop)
        try await store.delete(id: drop.id)
        let remaining = try await store.recent(limit: 10, view: .init("home"))
        #expect(remaining.map(\.id) == [keep.id])
        #expect(try await store.search(query: "forget", limit: 10).isEmpty)
    }

    @Test func sessionUsageRecordPersistsTaskIndependentStats() throws {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AIKitSessionUsageRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(3.5)
        let record = AIKitSessionUsageRecord(
            taskID: "task-123",
            modelName: "doubao-seed-2-0-lite-260215",
            providerName: "Volcengine Ark",
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: 3.5,
            roundTripCount: 2,
            messageCount: 4,
            usage: TokenUsage(inputTokens: 120, outputTokens: 34),
            outcome: .completed,
            recordedAt: endedAt
        )

        context.insert(record)
        try context.save()

        let fetched = try #require(context.fetch(
            FetchDescriptor<AIKitSessionUsageRecord>()
        ).first)
        #expect(fetched.taskID == "task-123")
        #expect(fetched.modelName == "doubao-seed-2-0-lite-260215")
        #expect(fetched.providerName == "Volcengine Ark")
        #expect(fetched.startedAt == startedAt)
        #expect(fetched.endedAt == endedAt)
        #expect(fetched.durationSeconds == 3.5)
        #expect(fetched.roundTripCount == 2)
        #expect(fetched.messageCount == 4)
        #expect(fetched.usage == TokenUsage(inputTokens: 120, outputTokens: 34))
        #expect(fetched.totalTokens == 154)
        #expect(fetched.outcome == .completed)
    }

    @Test func sessionUsageRecordClampsTokenAccessors() {
        let record = AIKitSessionUsageRecord(
            taskID: "task-123",
            modelName: "doubao-seed-2-0-lite-260215",
            durationSeconds: 1,
            roundTripCount: 1,
            inputTokens: 1,
            outputTokens: 2
        )

        record.inputTokens = -10
        record.outputTokens = -20

        #expect(record.usage == .zero)
        #expect(record.totalTokens == 0)

        record.usage = TokenUsage(inputTokens: -30, outputTokens: 40)

        #expect(record.inputTokens == 0)
        #expect(record.outputTokens == 40)
        #expect(record.totalTokens == 40)
    }

    @Test func swiftDataSessionUsageStorePersistsSummary() async throws {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AIKitSessionUsageRecord.self,
            configurations: configuration
        )
        let store = SwiftDataSessionUsageStore(modelContainer: container)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(2)
        let id = UUID()

        try await store.record(AIKitSessionUsageSummary(
            id: id,
            taskID: "turn-1",
            modelName: "doubao-seed-2-0-lite-260215",
            providerName: "Volcengine Ark",
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: 2,
            roundTripCount: 1,
            messageCount: 2,
            usage: TokenUsage(inputTokens: 10, outputTokens: 5),
            outcome: .completed,
            recordedAt: endedAt
        ))

        let context = ModelContext(container)
        let fetched = try #require(context.fetch(
            FetchDescriptor<AIKitSessionUsageRecord>()
        ).first)
        #expect(fetched.id == id)
        #expect(fetched.taskID == "turn-1")
        #expect(fetched.messageCount == 2)
        #expect(fetched.usage == TokenUsage(inputTokens: 10, outputTokens: 5))
        #expect(fetched.outcome == .completed)
    }

    @Test func swiftDataSessionUsageStoreUpsertsSummaryByID() async throws {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AIKitSessionUsageRecord.self,
            configurations: configuration
        )
        let store = SwiftDataSessionUsageStore(modelContainer: container)
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(2)

        try await store.record(AIKitSessionUsageSummary(
            id: id,
            taskID: "turn-1",
            modelName: "doubao-seed-2-0-lite-260215",
            providerName: "Volcengine Ark",
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: 2,
            roundTripCount: 1,
            messageCount: 2,
            usage: TokenUsage(inputTokens: 10, outputTokens: 5),
            outcome: .completed,
            recordedAt: endedAt
        ))
        try await store.record(AIKitSessionUsageSummary(
            id: id,
            taskID: "turn-1",
            modelName: "doubao-seed-2-0-pro-260515",
            providerName: "Volcengine Ark",
            startedAt: startedAt,
            endedAt: endedAt.addingTimeInterval(1),
            durationSeconds: 3,
            roundTripCount: 2,
            messageCount: 3,
            usage: TokenUsage(inputTokens: 20, outputTokens: 8),
            outcome: .failed,
            recordedAt: endedAt.addingTimeInterval(1)
        ))

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<AIKitSessionUsageRecord>())
        let fetched = try #require(records.first)
        #expect(records.count == 1)
        #expect(fetched.id == id)
        #expect(fetched.modelName == "doubao-seed-2-0-pro-260515")
        #expect(fetched.durationSeconds == 3)
        #expect(fetched.roundTripCount == 2)
        #expect(fetched.messageCount == 3)
        #expect(fetched.usage == TokenUsage(inputTokens: 20, outputTokens: 8))
        #expect(fetched.outcome == .failed)
    }
}

@Suite struct AIKitConfigurationToolTests {
    @Test func configurationToolsReadAndMutateStore() async throws {
        let store = AIKitConfigurationStore()
        let registry = ToolRegistry()
        await AIKitConfigurationTools.register(in: registry, store: store)

        let names = await registry.registeredNames()
        #expect(names.contains(GetAIKitConfigurationTool.toolName))
        #expect(names.contains(SetAIKitConfigurationTool.toolName))

        let context = ToolContext(viewID: "settings")
        let setInput = SetAIKitConfigurationTool.Input(
            section: .runtime,
            key: "maxIterations",
            value: .int(4)
        )
        let setData = jsonData(setInput)
        let outputData = try await registry.call(
            name: SetAIKitConfigurationTool.toolName,
            jsonArguments: setData,
            context: context
        )
        let output = try generatedValue(SetAIKitConfigurationTool.Output.self, from: outputData)

        #expect(output.applied)
        #expect(output.configuration.objectValue?["runtime"]?.objectValue?["maxIterations"]?.intValue == 4)

        let snapshot = await store.snapshot()
        #expect(snapshot.runtime.maxIterations == 4)

        let getData = jsonData(GetAIKitConfigurationTool.Input())
        let readData = try await registry.call(
            name: GetAIKitConfigurationTool.toolName,
            jsonArguments: getData,
            context: context
        )
        let read = try generatedValue(GetAIKitConfigurationTool.Output.self, from: readData)
        #expect(read.configuration.objectValue?["runtime"]?.objectValue?["maxIterations"]?.intValue == 4)
        #expect(read.recentChanges.arrayValue?.count == 1)
    }

    @Test func configurationStoreAcceptsStringSetUpdates() async throws {
        let store = AIKitConfigurationStore()
        _ = try await store.set(
            section: .capability,
            key: "enabledToolNames",
            value: .array([.string("navigate"), .string("searchMemory")])
        )

        let snapshot = await store.snapshot()
        #expect(snapshot.capability.enabledToolNames == ["navigate", "searchMemory"])
    }

    @Test func runtimeDefaultsFollowWorkflowGuidance() {
        let configuration = AIKitConfiguration.standard

        #expect(configuration.core.temperature == 0.2)
        #expect(configuration.runtime.workflowPlanning)
        #expect(configuration.runtime.leanWorkflowSchema)
        #expect(configuration.runtime.twoRoundAutoBind)
        #expect(configuration.runtime.twoRoundStructuredPlannerOutput == false)
    }

    @Test func runtimeDecodesMissingWorkflowFieldsWithDefaults() throws {
        let data = Data("""
        {
          "streamsResponses": false,
          "maxIterations": 3,
          "toolCallFallback": "automatic"
        }
        """.utf8)

        let runtime = try JSONDecoder().decode(AIKitConfiguration.Runtime.self, from: data)

        #expect(runtime.streamsResponses == false)
        #expect(runtime.maxIterations == 3)
        #expect(runtime.workflowPlanning)
        #expect(runtime.leanWorkflowSchema)
        #expect(runtime.twoRoundAutoBind)
        #expect(runtime.twoRoundStructuredPlannerOutput == false)
    }

    @Test func configurationStoreAcceptsWorkflowRuntimeUpdates() async throws {
        let store = AIKitConfigurationStore()

        _ = try await store.set(
            section: .runtime,
            key: "leanWorkflowSchema",
            value: .bool(false)
        )
        _ = try await store.set(
            section: .runtime,
            key: "twoRoundStructuredPlannerOutput",
            value: .bool(true)
        )

        let snapshot = await store.snapshot()
        #expect(snapshot.runtime.leanWorkflowSchema == false)
        #expect(snapshot.runtime.twoRoundStructuredPlannerOutput)
    }

    @Test func coreStoresProviderConfigurationsIndependently() {
        var core = AIKitConfiguration.Core(activeProvider: .ark)
        var ark = core.activeProviderConfiguration
        ark.defaultModel = "doubao-seed-1-6"
        ark.endpointURL = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        core.activeProviderConfiguration = ark

        core.activeProvider = .appleIntelligence
        var appleIntelligence = core.activeProviderConfiguration
        appleIntelligence.defaultModel = "private-cloud-compute"
        core.activeProviderConfiguration = appleIntelligence

        #expect(core.providerConfiguration(for: .ark).defaultModel == "doubao-seed-1-6")
        #expect(
            core.providerConfiguration(for: .ark).endpointURL ==
            "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        )
        #expect(
            core.providerConfiguration(for: .appleIntelligence).defaultModel ==
            "private-cloud-compute"
        )
    }

    @Test func refreshedModelListKeepsOnlyStillAvailableDefault() {
        var provider = AIKitConfiguration.Core.ProviderConfiguration(
            defaultModel: "doubao-seed-2-0-pro-260515",
            availableModels: ["doubao-seed-2-0-pro-260515"]
        )

        provider.replaceAvailableModels([
            "doubao-seed-2-0-lite-260215",
            "doubao-seed-2-0-pro-260515",
        ])
        #expect(provider.defaultModel == "doubao-seed-2-0-pro-260515")
        #expect(provider.availableModels == [
            "doubao-seed-2-0-lite-260215",
            "doubao-seed-2-0-pro-260515",
        ])

        provider.replaceAvailableModels(["doubao-seed-2-0-lite-260215"])
        #expect(provider.defaultModel == nil)

        provider.defaultModel = "doubao-seed-2-0-lite-260215"
        provider.replaceAvailableModels([])
        #expect(provider.defaultModel == nil)
        #expect(provider.availableModels == [])
    }

    @Test func corePersistsArkAvailableModels() throws {
        let configuration = AIKitConfiguration(core: .init(
            activeProvider: .ark,
            ark: .init(
                defaultModel: "doubao-seed-1-6",
                availableModels: ["doubao-seed-1-6", "doubao-seed-2-0-lite-260215"]
            )
        ))

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AIKitConfiguration.self, from: data)

        #expect(decoded.core.activeProvider == .ark)
        #expect(decoded.core.providerConfiguration(for: .ark).defaultModel == "doubao-seed-1-6")
        #expect(decoded.core.providerConfiguration(for: .ark).availableModels == [
            "doubao-seed-1-6",
            "doubao-seed-2-0-lite-260215",
        ])
    }

    @Test func corePersistsArkConfigurationAndEndpointURL() throws {
        let configuration = AIKitConfiguration(core: .init(
            activeProvider: .ark,
            ark: .init(
                defaultModel: "doubao-seed-1-6",
                availableModels: ["doubao-seed-1-6"],
                endpointURL: "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
            )
        ))

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AIKitConfiguration.self, from: data)

        #expect(decoded.core.activeProvider == .ark)
        #expect(decoded.core.providerConfiguration(for: .ark).defaultModel == "doubao-seed-1-6")
        #expect(
            decoded.core.providerConfiguration(for: .ark).endpointURL ==
            "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        )
    }

    @Test func corePersistsAppleIntelligenceConfiguration() throws {
        let configuration = AIKitConfiguration(core: .init(
            activeProvider: .appleIntelligence,
            appleIntelligence: .init(
                defaultModel: "apple-intelligence",
                availableModels: ["apple-intelligence", "private-cloud-compute"]
            )
        ))

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AIKitConfiguration.self, from: data)

        #expect(decoded.core.activeProvider == .appleIntelligence)
        #expect(
            decoded.core.providerConfiguration(for: .appleIntelligence).defaultModel ==
            "apple-intelligence"
        )
        #expect(decoded.core.providerConfiguration(for: .appleIntelligence).availableModels == [
            "apple-intelligence",
            "private-cloud-compute",
        ])
    }

}
