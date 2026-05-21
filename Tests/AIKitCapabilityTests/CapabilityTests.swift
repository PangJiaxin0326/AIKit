import Foundation
import Testing
@testable import AIKitCapability
import AIKitCore
import AIKitToolKit

private struct EchoTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var echoed: String }

    static let name = "echo"
    static let description = "Echoes input back, recording the call in memory."
    static let schema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    let memory: any MemoryStore

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        try await memory.append(UsageEvent(
            viewID: ViewContext.ID(context.viewID),
            kind: .toolInvoked,
            text: "echo:\(input.text)"
        ))
        return Output(echoed: input.text)
    }
}

@Suite struct ToolRegistryTests {
    @Test func registerInvokeAndMemory() async throws {
        let registry = ToolRegistry()
        let memory = InMemoryMemoryStore()
        await registry.register(EchoTool(memory: memory))
        let context = ToolContext(viewID: "home")

        let input = try JSONEncoder().encode(EchoTool.Input(text: "hi"))
        let outData = try await registry.invoke(
            name: "echo", jsonInput: input, context: context
        )
        let output = try JSONDecoder().decode(EchoTool.Output.self, from: outData)
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

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.self) {
            try await registry.invoke(
                name: "nope",
                jsonInput: Data("{}".utf8),
                context: ToolContext(viewID: "v")
            )
        }
    }
}

@Suite struct ContextResolverTests {
    @Test func pushPopMerge() async {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("root"),
            displayName: "Root",
            systemPromptFragment: "You are root.",
            toolNames: ["navigate"]
        ))
        await resolver.push(ViewContext(
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

        await resolver.pop(.init("settings"))
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

@Suite struct MemoryStoreTests {
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
}

@Suite struct AIKitConfigurationToolTests {
    @Test func configurationToolsReadAndMutateStore() async throws {
        let store = AIKitConfigurationStore()
        let registry = ToolRegistry()
        await AIKitConfigurationTools.register(in: registry, store: store)

        let names = await registry.registeredNames()
        #expect(names.contains(GetAIKitConfigurationTool.name))
        #expect(names.contains(SetAIKitConfigurationTool.name))

        let context = ToolContext(viewID: "settings")
        let setInput = SetAIKitConfigurationTool.Input(
            section: .runtime,
            key: "maxIterations",
            value: 4
        )
        let setData = try JSONEncoder().encode(setInput)
        let outputData = try await registry.invoke(
            name: SetAIKitConfigurationTool.name,
            jsonInput: setData,
            context: context
        )
        let output = try JSONDecoder().decode(
            SetAIKitConfigurationTool.Output.self,
            from: outputData
        )

        #expect(output.applied)
        #expect(output.configuration.runtime.maxIterations == 4)

        let snapshot = await store.snapshot()
        #expect(snapshot.runtime.maxIterations == 4)

        let getData = try JSONEncoder().encode(GetAIKitConfigurationTool.Input())
        let readData = try await registry.invoke(
            name: GetAIKitConfigurationTool.name,
            jsonInput: getData,
            context: context
        )
        let read = try JSONDecoder().decode(
            GetAIKitConfigurationTool.Output.self,
            from: readData
        )
        #expect(read.configuration.runtime.maxIterations == 4)
        #expect(read.recentChanges.count == 1)
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
}
