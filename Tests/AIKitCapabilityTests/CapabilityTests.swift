import Foundation
import Testing
@testable import AIKitCapability
import AIKitCore

private struct EchoTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var echoed: String }

    static let name = "echo"
    static let description = "Echoes input back, recording the call in memory."
    static let schema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        try await context.memory.append(UsageEvent(
            viewID: context.viewID,
            kind: .toolInvoked,
            text: "echo:\(input.text)"
        ))
        return Output(echoed: input.text)
    }
}

@Suite struct ToolRegistryTests {
    @Test func registerInvokeAndMemory() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let memory = InMemoryMemoryStore()
        let context = ToolContext(viewID: .init("home"), memory: memory)

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
        await registry.register(EchoTool())
        await registry.register(SearchMemoryTool())
        let all = await registry.manifest(for: [])
        #expect(all.count == 2)
        let subset = await registry.manifest(for: ["echo"])
        #expect(subset.map(\.name) == ["echo"])
    }

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.self) {
            try await registry.invoke(
                name: "nope",
                jsonInput: Data("{}".utf8),
                context: ToolContext(viewID: .init("v"), memory: InMemoryMemoryStore())
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

    @Test func sqliteRoundTrip() async throws {
        let store = try SQLiteMemoryStore(path: nil)
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

    @Test func sqliteSearchEscapesLikeWildcards() async throws {
        let store = try SQLiteMemoryStore(path: nil)
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
}
