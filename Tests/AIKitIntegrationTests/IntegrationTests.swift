import Foundation
import FoundationModels
import Testing
import AIToolKit
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety
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
        await registry.register(NavigateTool { _ in .init(navigated: true) })

        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    arguments: .object(["destination": .string("profile")])
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
        await registry.register(NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        })

        // The model asks for `navigate`, but the policy only allows `searchMemory`.
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    arguments: .object(["destination": .string("admin")])
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
        // The host registers only its own tool: `reportFailure` is provided
        // by the orchestrator itself — neither registered, nor in the
        // context's toolNames, nor in the allowlist.
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in .init(navigated: true) })

        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "f1", name: ReportFailureTool.toolName,
                    arguments: .object(["reason": .string("Your request is too vague.")])
                )],
                stopReason: .toolUse
            )
        ])

        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: ["navigate"])]),
            options: .init(model: "test", stream: false, workflowPlanning: false)
        )

        var failure: String?
        for try await event in await orchestrator.run("do the thing") {
            if case .failure(let reason) = event { failure = reason }
            if case .finalAnswer = event { Issue.record("should not finalize") }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(failure == "Your request is too vague.")

        // The default-provided tool was advertised to the model alongside the
        // view's own subset.
        let request = try #require(provider.receivedRequests.first)
        #expect(request.tools.contains { $0.name == ReportFailureTool.toolName })

        // The turn landed in the failed state, sticky on the task record.
        let task = try #require(await orchestrator.snapshot().recentTasks.first)
        #expect(task.failureReason == "Your request is too vague.")
    }

    @Test func reportFailureEndsPlanningModeTurnOnDirectCall() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        })

        // Planning mode rejects direct tool calls as malformed plans — but a
        // direct `reportFailure` call is a refusal and must end the turn.
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "f1", name: ReportFailureTool.toolName,
                    arguments: .object(["reason": .string("No tool can do that.")])
                )],
                stopReason: .toolUse
            )
        ])

        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, workflowPlanning: true)
        )

        var failure: String?
        for try await event in await orchestrator.run("do the impossible") {
            if case .failure(let reason) = event { failure = reason }
            if case .finalAnswer = event { Issue.record("should not finalize") }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(failure == "No tool can do that.")
        #expect(await flag.didInvoke == false)
        #expect(provider.receivedRequests.count == 1)
    }

    @Test func reportFailureWorkflowNodeEndsTurnAsRefusal() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        })

        // The model phrases the refusal as a one-node workflow plan. It must
        // surface as a failure, not execute as a no-op tool and "succeed".
        let spec = try GeneratedContent(json: """
        {"schema_version":"\(WorkflowSpec.schemaVersion)","nodes":[\
        {"id":"bail","tool":"\(ReportFailureTool.toolName)",\
        "input":{"reason":"The ask is ambiguous."}}]}
        """)
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(id: "w1", name: WorkflowSpec.toolName, arguments: spec)],
                stopReason: .toolUse
            )
        ])

        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, workflowPlanning: true)
        )

        var failure: String?
        for try await event in await orchestrator.run("do something vague") {
            if case .failure(let reason) = event { failure = reason }
            if case .finalAnswer = event { Issue.record("should not finalize") }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(failure == "The ask is ambiguous.")
        #expect(await flag.didInvoke == false)
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
