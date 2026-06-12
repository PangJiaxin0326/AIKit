import Foundation
import FoundationModels
import Testing
import AIToolKit
import VolcengineArkFoundationModels
import AIKitCore
import AIKitCapability
@testable import AIKitRuntime
import AIKitSafety
import AIKitTestSupport

private func mockModel(_ model: MockLanguageModel) -> OrchestratorModel {
    OrchestratorModel(model: model, modelID: "mock-model", providerName: "Mock")
}

@Suite struct PromptRendererTests {
    @Test func instructionsIncludePreambleAndFragment() {
        let context = ResolvedContext(
            stack: [.init("home")],
            systemPromptFragment: "You can navigate.",
            toolNames: ["navigate"],
            metadata: [:]
        )
        let instructions = PromptRenderer.instructions(for: context)
        #expect(instructions.hasPrefix(PromptRenderer.basePreamble))
        #expect(instructions.contains("You can navigate."))
    }

    @Test func renderCarriesPromptAndToolNames() {
        let context = ResolvedContext(
            stack: [.init("home")],
            systemPromptFragment: "",
            toolNames: ["navigate"],
            metadata: [:]
        )
        let rendered = PromptRenderer.render(
            instruction: "go to settings", context: context
        )
        #expect(rendered.userPrompt == "go to settings")
        #expect(rendered.toolNames == ["navigate"])
        #expect(rendered.instructions.hasPrefix(PromptRenderer.basePreamble))
    }
}

@Suite struct RetryPolicyTests {
    @Test func exponentialBackoffCaps() {
        let backoff = RetryPolicy.Backoff.exponential(base: 1, cap: 4)
        #expect(backoff.delay(forAttempt: 1) == 1)
        #expect(backoff.delay(forAttempt: 2) == 2)
        #expect(backoff.delay(forAttempt: 3) == 4)
        #expect(backoff.delay(forAttempt: 10) == 4)
    }

    @Test func classifierUsesOfficialTaxonomy() {
        #expect(ErrorClassifier.category(of: LanguageModelError.guardrailViolation(
            .init(debugDescription: "Blocked by builtin.allowlistedTools: no")
        )) == .guardrailViolation)
        #expect(ErrorClassifier.category(
            of: GenericToolError(message: "x", isRetriable: true)
        ) == .toolRetriable)
        #expect(ErrorClassifier.category(
            of: GenericToolError(message: "x")
        ) == .fatal)
        // The official wrapper around a tool-thrown error classifies as what
        // it wraps.
        #expect(ErrorClassifier.category(of: LanguageModelSession.ToolCallError(
            tool: NavigateTool { _ in .init(navigated: true) },
            underlyingError: GenericToolError(message: "x", isRetriable: true)
        )) == .toolRetriable)
        #expect(ErrorClassifier.category(of: LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "429")
        )) == .transient)
        #expect(ErrorClassifier.category(of: LanguageModelError.timeout(
            .init(debugDescription: "slow")
        )) == .transient)
        #expect(ErrorClassifier.category(
            of: VolcengineArkError.httpStatus(code: 429, body: "")
        ) == .transient)
        #expect(ErrorClassifier.category(
            of: VolcengineArkError.httpStatus(code: 503, body: "")
        ) == .transient)
        #expect(ErrorClassifier.category(
            of: VolcengineArkError.httpStatus(code: 400, body: "")
        ) == .fatal)
        #expect(ErrorClassifier.category(
            of: VolcengineArkError.transport("offline")
        ) == .transient)
        #expect(ErrorClassifier.category(
            of: PrivateCloudComputeLanguageModel.Error.networkFailure(
                .init(debugDescription: "offline")
            )
        ) == .transient)
    }

    @Test func handlerAbortsGuardrailImmediately() async {
        let handler = ErrorHandler()
        let decision = await handler.handle(
            LanguageModelError.guardrailViolation(.init(debugDescription: "no")),
            attempt: 1,
            policy: .default
        )
        guard case .abort(let error) = decision else {
            Issue.record("expected abort")
            return
        }
        #expect(ErrorClassifier.category(of: error) == .guardrailViolation)
    }

    @Test func handlerRetriesTransientUntilAttemptsExhaust() async {
        let handler = ErrorHandler()
        let policy = RetryPolicy(maxAttempts: 2, backoff: .none)
        let rateLimited = LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "429")
        )

        guard case .retry = await handler.handle(
            rateLimited, attempt: 1, policy: policy
        ) else {
            Issue.record("expected retry on first attempt")
            return
        }
        guard case .abort = await handler.handle(
            rateLimited, attempt: 2, policy: policy
        ) else {
            Issue.record("expected abort once attempts exhaust")
            return
        }
    }
}

@Suite struct OrchestratorTests {
    private func makeOrchestrator(
        model: MockLanguageModel,
        guardrails: PolicyEngine = PolicyEngine(),
        usageRecorder: (any AIKitSessionUsageRecording)? = nil,
        options: Orchestrator.Options = .init(stream: false)
    ) async -> Orchestrator {
        let tools: [any Tool] = [NavigateTool { input in
            .init(navigated: input.destination == "settings")
        }]
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"),
            displayName: "Home",
            systemPromptFragment: "You can navigate.",
            toolNames: ["navigate"]
        ))
        return Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: guardrails,
            usageRecorder: usageRecorder,
            options: options
        )
    }

    /// A fresh subscription's first emission is the current aggregate state.
    private func currentActivity(of orchestrator: Orchestrator) async -> OrchestratorActivity {
        var iterator = orchestrator.activityUpdates().makeAsyncIterator()
        return await iterator.next() ?? .idle
    }

    /// Turns are independent by construction: a later turn runs in a fresh
    /// session, so its transcript carries nothing from an earlier turn — not
    /// its instruction, not its tool calling, not its reply. (Durable memory
    /// is reachable only through the explicit `searchMemory` tool.)
    @Test func turnsDoNotSeeEarlierTurnsHistory() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "1", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
            .init(text: "Done, you're in settings."),
            .init(text: "Hello!"),
        ])
        let orchestrator = await makeOrchestrator(model: model)

        for try await event in await orchestrator.run("go to settings") {
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        var secondFinal: String?
        for try await event in await orchestrator.run("say hello") {
            if case .finalAnswer(let text) = event { secondFinal = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(secondFinal == "Hello!")

        let secondTurnRequest = try #require(model.receivedRequests.last)
        let prompts = secondTurnRequest.transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
        #expect(prompts == ["say hello"])
        let transcriptText = secondTurnRequest.transcript.map(\.description).joined()
        #expect(!transcriptText.contains("go to settings"))
        #expect(!transcriptText.contains("Done, you're in settings."))
    }

    @Test func externalWorkSurfacesBusyStateAndStatusText() async throws {
        let orchestrator = await makeOrchestrator(model: MockLanguageModel(turns: []))

        let id = await orchestrator.beginExternalWork()
        var activity = await currentActivity(of: orchestrator)
        #expect(activity.isBusy)
        #expect(activity.phase == .externalWork(nil))
        #expect(activity.statusText == "Thinking…")
        // External work drives live activity only — never task snapshots.
        #expect(activity.activeTasks.isEmpty)

        await orchestrator.updateExternalWork(id, statusText: "Creating Entry…")
        activity = await currentActivity(of: orchestrator)
        #expect(activity.phase == .externalWork("Creating Entry…"))
        #expect(activity.statusText == "Creating Entry…")

        await orchestrator.endExternalWork(id)
        activity = await currentActivity(of: orchestrator)
        #expect(!activity.isBusy)
        #expect(activity.phase == .idle)

        // Ended work stays ended: late updates and repeat ends are no-ops.
        await orchestrator.updateExternalWork(id, statusText: "stale")
        await orchestrator.endExternalWork(id)
        activity = await currentActivity(of: orchestrator)
        #expect(activity.phase == .idle)
    }

    @Test func cancelActiveTurnsCancelsExternalWork() async throws {
        let orchestrator = await makeOrchestrator(model: MockLanguageModel(turns: []))

        await confirmation("onCancel invoked") { cancelled in
            _ = await orchestrator.beginExternalWork(statusText: "Creating Entry…") {
                cancelled()
            }
            await orchestrator.cancelActiveTurns()
        }
        let activity = await currentActivity(of: orchestrator)
        #expect(!activity.isBusy)
        #expect(activity.phase == .idle)
    }

    @Test func endToEndToolThenFinal() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
            .init(text: "You're on settings now."),
        ])
        let orchestrator = await makeOrchestrator(model: model)

        var toolCalled = false
        var sawToolResult = false
        var finalAnswer: String?
        for try await event in await orchestrator.run("Go to settings") {
            switch event {
            case .toolCall(let call): toolCalled = (call.toolName == "navigate")
            case .toolResult(let call, _): sawToolResult = (call.toolName == "navigate")
            case .finalAnswer(let text): finalAnswer = text
            case .error(let error): Issue.record("unexpected error: \(error)")
            default: break
            }
        }
        #expect(toolCalled)
        #expect(sawToolResult)
        #expect(finalAnswer == "You're on settings now.")
    }

    @Test func snapshotGroupsActivityByTaskWithUsageAndDuration() async throws {
        // Both rounds report usage: the task must carry the SUM, not the
        // final round's numbers (`Response.usage` covers only the last
        // model call; the turn reads the session's accumulated usage).
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )], inputTokens: 100, outputTokens: 10),
            .init(text: "You're on settings now.", inputTokens: 15, outputTokens: 9),
        ])
        let orchestrator = await makeOrchestrator(model: model)

        for try await event in await orchestrator.run("Go to settings") {
            if case .error(let error) = event {
                Issue.record("unexpected error: \(error)")
            }
        }

        let snapshot = await orchestrator.snapshot(recentActivityLimit: 20)
        let task = try #require(snapshot.recentTasks.first)
        #expect(task.instruction == "Go to settings")
        #expect(task.isRunning == false)
        #expect(task.duration() >= 0)
        #expect(task.usage.inputTokens == 115)
        #expect(task.usage.outputTokens == 19)
        #expect(task.activities.contains { $0.kind == .userInstruction })
        #expect(task.activities.contains { $0.kind == .toolInvoked })
        #expect(task.activities.contains { $0.kind == .toolResult })
        #expect(task.activities.contains { $0.kind == .llmResponse })
    }

    @Test func finishedTurnRecordsSessionUsage() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )], inputTokens: 100, outputTokens: 10),
            .init(text: "You're on settings now.", inputTokens: 15, outputTokens: 9),
        ])
        let usageStore = InMemorySessionUsageStore()
        let orchestrator = await makeOrchestrator(
            model: model,
            usageRecorder: usageStore
        )

        for try await event in await orchestrator.run("Go to settings") {
            if case .error(let error) = event {
                Issue.record("unexpected error: \(error)")
            }
        }

        let summaries = await usageStore.all()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.taskID.hasPrefix("turn-"))
        #expect(summary.modelName == "mock-model")
        #expect(summary.providerName == "Mock")
        // One session call carries the whole turn (the tool rounds happen
        // inside it), so the turn counts one round trip.
        #expect(summary.roundTripCount == 1)
        #expect(summary.messageCount == 2)
        // Both rounds' usage, not just the final model call's.
        #expect(summary.usage == TokenUsage(inputTokens: 115, outputTokens: 19))
        #expect(summary.outcome == .completed)
    }

    private struct ScriptedProviderFailure: Error {}

    @Test func failedTurnStillRecordsConsumedUsage() async throws {
        // Round 1 (the tool call) consumes tokens; round 2 fails the turn.
        // The tokens the attempt burned must reach the task record and the
        // usage summary — they were spent regardless of the outcome.
        let model = MockLanguageModel(results: [
            .success(.init(toolCalls: [.init(
                id: "t1", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )], inputTokens: 100, outputTokens: 10)),
            .failure(ScriptedProviderFailure()),
        ])
        let usageStore = InMemorySessionUsageStore()
        let orchestrator = await makeOrchestrator(
            model: model,
            usageRecorder: usageStore,
            options: .init(stream: false, retry: RetryPolicy(maxAttempts: 1, backoff: .none))
        )

        var usageEvents: [TokenUsage] = []
        for try await event in await orchestrator.run("Go to settings") {
            if case .usage(let usage) = event {
                usageEvents.append(usage)
            }
        }

        #expect(usageEvents == [TokenUsage(inputTokens: 100, outputTokens: 10)])
        let summary = try #require(await usageStore.all().first)
        #expect(summary.usage == TokenUsage(inputTokens: 100, outputTokens: 10))
        #expect(summary.outcome == .failed)
    }

    @Test func cancelledTurnRecordsSessionUsageOnce() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "hang", argumentsJSON: "{}"
            )]),
            .init(text: "never reached"),
        ])
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["hang"]
        ))
        let usageStore = InMemorySessionUsageStore()
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: [HangingTool(delay: .seconds(5))],
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            usageRecorder: usageStore,
            options: .init(stream: false)
        )

        let stream = await orchestrator.run("Go to settings")
        let drainTask = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(100))
        await orchestrator.cancelActiveTurns()
        try await drainTask.value

        let summaries = await usageStore.all()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.outcome == .cancelled)
    }

    /// Mistyped tool arguments fail the session's strict typed decode and
    /// abort the attempt as the official `ToolCallError` wrapping
    /// `GeneratedContent.ParsingError` — classified retriable, so the turn
    /// retries with a fresh session and the model corrects the call. The
    /// tool only ever runs with valid input.
    @Test func malformedToolArgumentsRetryAndCorrect() async throws {
        let seen = SeenInput()
        let tools: [any Tool] = [NavigateTool { input in
            await seen.record(input.destination)
            return .init(navigated: true)
        }]
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "bad", name: "navigate",
                argumentsJSON: #"{"wrong":"field"}"#
            )]),
            .init(toolCalls: [.init(
                id: "good", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
            .init(text: "Corrected."),
        ])
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(stream: false, retry: .init(maxAttempts: 2, backoff: .none))
        )

        var final: String?
        for try await event in await orchestrator.run("go to settings") {
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(final == "Corrected.")
        #expect(await seen.value == "settings")
    }

    /// A retriable tool failure aborts the attempt (official `ToolCallError`)
    /// and the retry policy reruns the turn in a fresh session.
    @Test func retriableToolFailureIsRetriedAndRecovered() async throws {
        let attempts = ToolAttemptCounter()
        let tools: [any Tool] = [NavigateTool { _ in
            if await attempts.shouldFailOnce() {
                throw GenericToolError(message: "temporary navigation failure", isRetriable: true)
            }
            return .init(navigated: true)
        }]
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "first", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
            .init(toolCalls: [.init(
                id: "retry", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
            .init(text: "Recovered."),
        ])
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(stream: false, retry: .init(maxAttempts: 2, backoff: .none))
        )

        var final: String?
        var toolResults: [String] = []
        for try await event in await orchestrator.run("go to settings") {
            if case .toolResult(_, let output) = event {
                toolResults.append(output.contentText)
            }
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(final == "Recovered.")
        // The failed attempt produced no output entry — only the successful
        // retry's result is reported.
        #expect(toolResults.count == 1)
        #expect(toolResults.first?.contains("true") == true)
    }

    /// A tool-thrown error aborts the session call as the official
    /// `ToolCallError`; the turn loop unwraps it and the non-retriable
    /// contract aborts the turn. No output entry exists, so the postToolUse
    /// stage never runs for it.
    @Test func nonRetriableToolFailureAbortsTheTurn() async throws {
        let recorder = PostToolUseRecorder()
        let tools: [any Tool] = [NavigateTool { _ in
            throw GenericToolError(message: "permanent navigation failure")
        }]
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "failed", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
        ])
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [RecordingPostToolUseRail(recorder: recorder)]),
            options: .init(stream: false, retry: .init(maxAttempts: 1, backoff: .none))
        )

        var caught: (any Error)?
        for try await event in await orchestrator.run("go to settings") {
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is GenericToolError)
        #expect(await recorder.values == [])
    }

    /// A postToolUse block stops the turn with the official guardrail
    /// violation before the orchestrator reports the output to the host.
    @Test func postToolUseBlockSuppressesToolResultEvent() async throws {
        let tools: [any Tool] = [NavigateTool { _ in .init(navigated: true) }]
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "navigate",
                argumentsJSON: #"{"destination":"settings"}"#
            )]),
            .init(text: "never reached"),
        ])
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [BlockingPostToolUseRail()]),
            options: .init(stream: false, retry: .init(maxAttempts: 1, backoff: .none))
        )

        var caught: (any Error)?
        var emittedToolResult = false
        for try await event in await orchestrator.run("go to settings") {
            if case .toolResult = event { emittedToolResult = true }
            if case .error(let error) = event { caught = error }
        }
        guard let modelError = caught as? LanguageModelError,
              case .guardrailViolation = modelError else {
            Issue.record("expected guardrailViolation, got \(String(describing: caught))")
            return
        }
        #expect(emittedToolResult == false)
    }

    @Test func streamingEmitsDeltas() async throws {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            model: mockModel(MockLanguageModel(finalText: "hello stream")),
            tools: [],
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(stream: true)
        )
        var deltas: [String] = []
        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .llmDelta(let d) = event { deltas.append(d) }
            if case .finalAnswer(let f) = event { final = f }
        }
        #expect(deltas.joined() == "hello stream")
        #expect(final == "hello stream")
    }

    @Test func transientModelFailureRetriesWithFreshSession() async throws {
        let model = MockLanguageModel(results: [
            .failure(LanguageModelError.rateLimited(
                .init(resetDate: nil, debugDescription: "429")
            )),
            .success(.init(text: "second attempt")),
        ])
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: [],
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(stream: false, retry: .init(maxAttempts: 2, backoff: .none))
        )

        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(final == "second attempt")
        #expect(model.receivedRequests.count == 2)
    }

    /// PII in a tool's input blocks the call before it executes — the tool
    /// never sees the payload, and the turn fails with the official
    /// guardrail violation.
    @Test func piiGuardBlocksToolInputBeforeInvocation() async throws {
        let seen = SeenInput()
        let tools: [any Tool] = [NavigateTool { input in
            await seen.record(input.destination)
            return .init(navigated: true)
        }]
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "navigate",
                argumentsJSON: #"{"destination":"email me at a@b.com"}"#
            )]),
        ])
        let orchestrator = Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [PIIGuard()]),
            options: .init(stream: false, retry: .init(maxAttempts: 1, backoff: .none))
        )
        var caught: (any Error)?
        for try await event in await orchestrator.run("go") {
            if case .error(let error) = event { caught = error }
        }
        guard let modelError = caught as? LanguageModelError,
              case .guardrailViolation = modelError else {
            Issue.record("expected guardrailViolation, got \(String(describing: caught))")
            return
        }
        #expect(await seen.value == nil)
    }
}

@Suite struct ReasoningEventTests {
    @Test func reasoningSurfacesOncePerCall() async throws {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            model: mockModel(MockLanguageModel(turns: [
                .init(text: "answer", reasoning: "let me think"),
            ])),
            tools: [],
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(stream: false)
        )
        var reasoning: [String] = []
        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .reasoningDelta(let r) = event { reasoning.append(r) }
            if case .finalAnswer(let f) = event { final = f }
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        #expect(final == "answer")
        #expect(reasoning == ["let me think"])
    }
}

@Suite struct TurnDeadlineTests {
    private func makeOrchestrator(
        model: MockLanguageModel,
        tools: [any Tool],
        toolNames: Set<String>,
        guardrails: PolicyEngine = PolicyEngine(),
        budget: TimeInterval
    ) async -> Orchestrator {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("v"), displayName: "V", toolNames: toolNames
        ))
        return Orchestrator(
            model: mockModel(model),
            tools: tools,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: guardrails,
            options: .init(
                stream: false,
                retry: .init(maxAttempts: 1, backoff: .none),
                maxTurnDuration: budget
            )
        )
    }

    @Test func zeroBudgetAbortsImmediately() async throws {
        let orchestrator = await makeOrchestrator(
            model: MockLanguageModel(finalText: "late"),
            tools: [],
            toolNames: [],
            budget: 0
        )
        var caught: (any Error)?
        for try await event in await orchestrator.run("hi") {
            if case .error(let error) = event { caught = error }
            if case .finalAnswer = event { Issue.record("should not answer") }
        }
        #expect(caught is TurnDeadlineExceeded)
    }

    @Test func deadlineInterruptsHangingTool() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(id: "t1", name: "hang", argumentsJSON: "{}")]),
            .init(text: "never"),
        ])
        let orchestrator = await makeOrchestrator(
            model: model,
            tools: [HangingTool(delay: .seconds(10))],
            toolNames: ["hang"],
            budget: 0.2
        )

        let clock = ContinuousClock()
        let start = clock.now
        var caught: (any Error)?
        for try await event in await orchestrator.run("hang") {
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is TurnDeadlineExceeded)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func deadlineInterruptsSlowGuardrail() async throws {
        let orchestrator = await makeOrchestrator(
            model: MockLanguageModel(finalText: "late"),
            tools: [],
            toolNames: [],
            guardrails: PolicyEngine(rails: [SlowPrePromptRail(delay: .seconds(10))]),
            budget: 0.2
        )

        let clock = ContinuousClock()
        let start = clock.now
        var caught: (any Error)?
        for try await event in await orchestrator.run("hi") {
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is TurnDeadlineExceeded)
        #expect(clock.now - start < .seconds(5))
    }
}

// MARK: - Helpers

private actor SeenInput {
    private(set) var value: String?
    func record(_ v: String) { value = v }
}

private actor ToolAttemptCounter {
    private var attempts = 0

    func shouldFailOnce() -> Bool {
        attempts += 1
        return attempts == 1
    }
}

private actor PostToolUseRecorder {
    private(set) var values: [String] = []

    func record(_ toolName: String) {
        values.append(toolName)
    }
}

private struct RecordingPostToolUseRail: Guardrail {
    let id = "record-post-tool-use"
    let stages: Set<GuardrailStage> = [.postToolUse]
    let recorder: PostToolUseRecorder

    func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
        if case .postToolUse(let call, _) = payload {
            await recorder.record(call.toolName)
        }
        return .pass
    }
}

private struct BlockingPostToolUseRail: Guardrail {
    let id = "block-post-tool-use"
    let stages: Set<GuardrailStage> = [.postToolUse]

    func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
        if case .postToolUse = payload {
            return .block(reason: "blocked tool output")
        }
        return .pass
    }
}

private struct SlowPrePromptRail: Guardrail {
    let id = "slow-pre-prompt"
    let stages: Set<GuardrailStage> = [.prePrompt]
    let delay: Duration

    func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
        try? await Task.sleep(for: delay)
        return .pass
    }
}

/// Sleeps before answering, so a turn deadline or a cancellation must
/// interrupt it.
private struct HangingTool: Tool {
    @Generable
    struct Input: Codable, Sendable {
        init() {}
    }
    @Generable
    struct Output: Codable, Sendable {
        var ok: Bool
    }

    let name = "hang"
    let description = "Hangs for a while."
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func call(arguments input: Input) async throws -> Output {
        try await Task.sleep(for: delay)
        return Output(ok: true)
    }
}
