import Foundation
import Testing
import AIKit
import AIKitTestSupport

/// A tool that flips a flag when invoked, so tests can prove a blocked call
/// never reaches it.
private actor InvocationFlag {
    private(set) var didInvoke = false
    func mark() { didInvoke = true }
}

@Suite struct IntegrationTests {
    private func resolver(toolNames: Set<String>) async -> ContextResolver {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"),
            displayName: "Home",
            systemPromptFragment: "Assist the user.",
            toolNames: toolNames
        ))
        return resolver
    }

    @Test func fullLoopToolThenFinalAnswer() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in .init(navigated: true) })

        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    input: .object(["destination": .string("profile")])
                )],
                stopReason: .toolUse
            ),
            LLMResponse(content: [.text("Done — you're on profile.")], stopReason: .endTurn),
        ])

        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: ["navigate"])]),
            options: .init(model: "test", stream: false, workflowPlanning: false)
        )

        var final: String?
        for try await event in await orchestrator.run("Open my profile") {
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(final == "Done — you're on profile.")
    }

    @Test func blockedToolShortCircuitsAndNeverInvokes() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            await flag.mark()
            return .init(navigated: true)
        })

        // The model asks for `navigate`, but the policy only allows `searchMemory`.
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    input: .object(["destination": .string("admin")])
                )],
                stopReason: .toolUse
            )
        ])

        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: ["searchMemory"])]),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 1), workflowPlanning: false
            )
        )

        var caught: (any Error)?
        for try await event in await orchestrator.run("sneak into admin") {
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is GuardrailViolation)
        let invoked = await flag.didInvoke
        #expect(invoked == false)
    }

    @Test func reportFailureEndsTurnWithReason() async throws {
        let registry = ToolRegistry()
        await registry.register(ReportFailureTool())

        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "f1", name: ReportFailureTool.name,
                    input: .object(["reason": .string("Your request is too vague.")])
                )],
                stopReason: .toolUse
            )
        ])

        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: [ReportFailureTool.name]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: [ReportFailureTool.name])]),
            options: .init(model: "test", stream: false, workflowPlanning: false)
        )

        var failure: String?
        for try await event in await orchestrator.run("do the thing") {
            if case .failure(let reason) = event { failure = reason }
            if case .finalAnswer = event { Issue.record("should not finalize") }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(failure == "Your request is too vague.")
    }

    @Test func fiftyConcurrentOrchestratorsAreIsolated() async throws {
        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let registry = ToolRegistry()
                    let resolver = ContextResolver()
                    await resolver.push(ViewContext(id: .init("v\(i)"), displayName: "V"))
                    let orchestrator = Orchestrator(
                        llm: LLMClient(provider: MockProvider(finalText: "answer-\(i)")),
                        tools: registry,
                        memory: InMemoryMemoryStore(),
                        contextResolver: resolver,
                        guardrails: PolicyEngine(),
                        options: .init(model: "test", stream: false)
                    )
                    var final: String?
                    for try await event in await orchestrator.run("q\(i)") {
                        if case .finalAnswer(let t) = event { final = t }
                    }
                    return final
                }
            }
            var results: Set<String> = []
            for try await value in group {
                if let value { results.insert(value) }
            }
            #expect(results.count == 50)
        }
    }
}
