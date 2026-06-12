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

private func mockModel(_ model: MockLanguageModel) -> OrchestratorModel {
    OrchestratorModel(model: model, modelID: "mock-model", providerName: "Mock")
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
        let tools: [any Tool] = [NavigateTool { _ in .init(navigated: true) }]

        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1",
                name: "navigate",
                argumentsJSON: #"{"destination":"profile"}"#
            )]),
            .init(text: "Done — you're on profile."),
        ])

        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: ["navigate"])]),
            options: .init(stream: false)
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
        let tools: [any Tool] = [NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        }]

        // The model asks for `navigate`, but the policy only allows `searchMemory`.
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1",
                name: "navigate",
                argumentsJSON: #"{"destination":"admin"}"#
            )]),
        ])

        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: ["searchMemory"])]),
            options: .init(stream: false, retry: .init(maxAttempts: 1))
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
        // The host hands over only its own tool: `reportFailure` is provided
        // by the orchestrator itself — neither passed in, nor in the
        // context's toolNames, nor in the allowlist.
        let tools: [any Tool] = [NavigateTool { _ in .init(navigated: true) }]

        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "f1",
                name: ReportFailureTool.toolName,
                argumentsJSON: #"{"reason":"Your request is too vague."}"#
            )]),
        ])

        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: await resolver(toolNames: ["navigate"]),
            guardrails: PolicyEngine(rails: [AllowlistedTools(allowed: ["navigate"])]),
            options: .init(stream: false)
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
        let request = try #require(model.receivedRequests.first)
        #expect(request.enabledToolDefinitions.contains {
            $0.name == ReportFailureTool.toolName
        })

        // The turn landed in the failed state, sticky on the task record.
        let task = try #require(await orchestrator.snapshot().recentTasks.first)
        #expect(task.failureReason == "Your request is too vague.")
    }

    @Test func fiftyConcurrentOrchestratorsAreIsolated() async throws {
        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let resolver = ContextResolver()
                    await resolver.push(ViewContext(id: .init("v\(i)"), displayName: "V"))
                    let orchestrator = Orchestrator(
                        model: mockModel(MockLanguageModel(finalText: "answer-\(i)")),
                        tools: [],
                        memory: InMemoryMemoryStore(),
                        contextResolver: resolver,
                        guardrails: PolicyEngine(),
                        options: .init(stream: false)
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
