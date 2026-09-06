import Foundation
import FoundationModels
import Synchronization
import Testing
import AIKit
import AIKitTestSupport

@Generable private struct AuditArguments { let text: String }

private final class AuditCounter: Sendable {
    let value = Mutex(0)
}

private actor AuditGate {
    var entered = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct AuditParkingTool: Tool {
    var name: String { "park" }
    var description: String { "Wait." }
    let gate: AuditGate
    func call(arguments: AuditArguments) async throws -> String {
        await gate.wait()
        return "done"
    }
}

private func auditSession(_ model: MockLanguageModel, tools: [any Tool] = []) -> LanguageModelSession {
    LanguageModelSession(profile: LanguageModelSession.Profile {
        Instructions("Help.")
        tools
    }.model(model))
}

private func parkedModel() -> MockLanguageModel {
    MockLanguageModel(turns: [
        .init(toolCalls: [.init(id: "park-1", name: "park", argumentsJSON: #"{"text":"go"}"#)], inputTokens: 3, outputTokens: 2),
        .init(text: "Done.", inputTokens: 5, outputTokens: 2),
    ])
}

@Suite(.serialized) struct ArchitectureRegressionTests {
    // Regressions for the audit's reproduced cross-boundary failures.
    @Test func deadlineBoundsBackoff() async throws {
        let model = MockLanguageModel(results: [
            .failure(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "retry"))),
        ])
        let conversation = AIKitConversation(
            session: auditSession(model),
            turnPolicy: .init(retry: .init(maxAttempts: 2, backoff: .fixed(seconds: 0.30)), deadline: 0.03)
        )
        let start = ContinuousClock.now
        await #expect(throws: TurnDeadlineExceeded.self) { try await conversation.respond(to: "hi") }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(250))
    }

    @Test func cancelAllCancelsAndWaitsForSettlement() async throws {
        let gate = AuditGate()
        let model = parkedModel()
        let store = AIKitActivityStore()
        let conversation = AIKitConversation(session: auditSession(model, tools: [AuditParkingTool(gate: gate)]), activity: store)
        let turn = Task { try await conversation.respond(to: "go") }
        while await !gate.entered { await Task.yield() }
        await store.cancelAll()
        #expect(await store.snapshot().isBusy)
        #expect(conversation.session.isResponding)
        await gate.open()
        await #expect(throws: CancellationError.self) { try await turn.value }
        #expect(await !store.snapshot().isBusy)
    }

    @Test func cancelledQueuedTurnSettlesIndependently() async throws {
        let gate = AuditGate()
        let conversation = AIKitConversation(session: auditSession(parkedModel(), tools: [AuditParkingTool(gate: gate)]))
        let first = Task { try await conversation.respond(to: "first") }
        while await !gate.entered { await Task.yield() }
        let settled = Mutex(false)
        let second = Task {
            defer { settled.withLock { $0 = true } }
            return try await conversation.respond(to: "second")
        }
        try await Task.sleep(for: .milliseconds(30))
        second.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(settled.withLock { $0 })
        await gate.open()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }
    }

    @Test func toolTurnCountsOneResponsePerModelRound() async throws {
        let gate = AuditGate()
        await gate.open()
        let model = parkedModel()
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(session: auditSession(model, tools: [AuditParkingTool(gate: gate)]), usageRecorder: recorder)
        _ = try await conversation.respond(to: "go")
        let record = try #require(await recorder.all().first)
        #expect(model.receivedRequests.count == 2)
        #expect(record.roundTripCount == 2)
    }

    @MainActor @Test func presenterUsesDeadlineAndActivity() async throws {
        let gate = AuditGate()
        let model = parkedModel()
        let store = AIKitActivityStore()
        let conversation = AIKitConversation(session: auditSession(model, tools: [AuditParkingTool(gate: gate)]), turnPolicy: .init(deadline: 0.02), activity: store)
        let presenter = AIKitConversationPresenter(conversation: conversation)
        let task = Task { await presenter.send("go") }
        while await !gate.entered { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(presenter.isResponding)
        #expect(await store.snapshot().isBusy)
        await gate.open()
        await task.value
        #expect(presenter.lastError?.contains("budget") == true)
        #expect(!presenter.lines.contains { $0.text == "Done." })
    }

    @MainActor @Test func presenterUnwrapsRefusal() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(id: "refuse", name: "reportFailure", argumentsJSON: #"{"reason":"cannot do this"}"#)], inputTokens: 5, outputTokens: 1),
        ])
        let session = makeRefusalSession(model)
        let recorder = InMemorySessionUsageStore()
        let presenter = AIKitConversationPresenter(conversation: AIKitConversation(session: session, usageRecorder: recorder))
        await presenter.send("go")
        let record = try #require(await recorder.all().first)
        #expect(record.outcome == .refused)
        #expect(presenter.lastError == "cannot do this")
    }

    @Test func defaultPolicyDoesNotReplaySideEffects() async throws {
        struct WriteTool: Tool {
            var name: String { "write" }
            var description: String { "Commit an external write." }
            let count: AuditCounter
            func call(arguments: AuditArguments) async throws -> String {
                count.value.withLock { $0 += 1 }
                return "committed"
            }
        }
        let count = AuditCounter()
        let model = MockLanguageModel(results: [
            .success(.init(toolCalls: [.init(id: "w1", name: "write", argumentsJSON: #"{"text":"go"}"#)])),
            .failure(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "429 after tool"))),
            .success(.init(toolCalls: [.init(id: "w2", name: "write", argumentsJSON: #"{"text":"go"}"#)])),
            .success(.init(text: "Done")),
        ])
        let conversation = AIKitConversation(session: auditSession(model, tools: [WriteTool(count: count)]))
        await #expect(throws: LanguageModelError.self) { try await conversation.respond(to: "write once") }
        #expect(count.value.withLock { $0 } == 1)
    }

    @Test func validatedStreamDoesNotExposeBlockedText() async throws {
        struct BlockResponse: Guardrail {
            let id = "audit.final"
            let stages: Set<GuardrailStage> = [.finalResult]
            func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome { .block(reason: "denied") }
        }
        let session = LanguageModelSession(profile: LanguageModelSession.Profile {
            Instructions("Help")
        }.model(MockLanguageModel(finalText: "blocked text")).guardrails(PolicyEngine(rails: [BlockResponse()])))
        let conversation = AIKitConversation(session: session)
        await #expect(throws: LanguageModelError.self) {
            try await conversation.collectResponse(to: "hi")
        }

    }

    @Test func cancelledTurnPersistsThroughCancellationAwareSink() async throws {
        actor Recorder: AIKitSessionUsageRecording {
            var rows: [AIKitSessionUsageSummary] = []
            func record(_ summary: AIKitSessionUsageSummary) async throws {
                try Task.checkCancellation()
                rows.append(summary)
            }
        }
        struct SleepTool: Tool {
            var name: String { "park" }
            var description: String { "Sleep" }
            let signal: AuditCounter
            func call(arguments: AuditArguments) async throws -> String {
                signal.value.withLock { $0 = 1 }
                try await Task.sleep(for: .seconds(60))
                return "done"
            }
        }
        let signal = AuditCounter()
        let recorder = Recorder()
        let conversation = AIKitConversation(session: auditSession(parkedModel(), tools: [SleepTool(signal: signal)]), usageRecorder: recorder)
        let task = Task { try await conversation.respond(to: "go") }
        while signal.value.withLock({ $0 }) == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(conversation.session.usage.input.totalTokenCount > 0)
        #expect(await recorder.rows.count == 1)
        #expect(await recorder.rows.first?.outcome == .cancelled)
    }

    @Test func preservedTranscriptRequiresRepairForRetry() async throws {
        let model = MockLanguageModel(results: [
            .failure(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "retry"))),
            .success(.init(text: "ok")),
        ])
        let conversation = AIKitConversation(session: auditSession(model), turnPolicy: .init(retry: .init(maxAttempts: 2, backoff: .none), transcriptErrorHandling: .preserveTranscript))
        await #expect(throws: LanguageModelError.self) { try await conversation.respond(to: "once") }
        let prompts = model.receivedRequests.last!.transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.contentText
        }
        #expect(prompts == ["once"])
        #expect(model.receivedRequests.count == 1)
    }
}

private func makeRefusalSession(_ model: MockLanguageModel) -> LanguageModelSession {
    LanguageModelSession(profile: LanguageModelSession.Profile {
        Instructions("Help")
        [ReportFailureTool() as any Tool]
    }.model(model).refusalEscapeHatch())
}

@Suite struct ArchitectureBoundaryTests {
    @Generable struct Answer: Sendable { var value: String }

    @Test func typedGenerationUsesTheSameLifecycle() async throws {
        let model = MockLanguageModel(finalText: #"{"value":"typed"}"#)
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(session: auditSession(model), usageRecorder: recorder)
        let response = try await conversation.respond(to: Prompt { "generate" }, generating: Answer.self)
        #expect(response.content.value == "typed")
        #expect(await recorder.all().count == 1)
    }

    @Test func metricsSurviveRollbackAndRetry() async throws {
        let metrics = AIKitTurnMetrics()
        let model = MockLanguageModel(results: [
            .success(.init(toolCalls: [.init(name: "park", argumentsJSON: #"{"text":"go"}"#)], inputTokens: 3, outputTokens: 1)),
            .failure(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "retry"))),
            .success(.init(text: "done", inputTokens: 2, outputTokens: 1)),
        ])
        let gate = AuditGate()
        await gate.open()
        let session = LanguageModelSession(profile: LanguageModelSession.Profile {
            Instructions("Help")
            AuditParkingTool(gate: gate)
        }.model(model).measuringRounds(with: metrics))
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(session: session,
            turnPolicy: .init(retry: .init(maxAttempts: 2, backoff: .none)),
            usageRecorder: recorder, metrics: metrics)
        _ = try await conversation.respond(to: "go")
        let row = try #require(await recorder.all().first)
        #expect(row.roundTripCount == 2)
        #expect(row.usage.inputTokens == 5)
    }

    @Test func snapshotStreamRetainsOnlyCurrentState() async throws {
        let store = AIKitConfigurationStore()
        let stream = await store.updates()
        for value in 1...100 {
            await store.update { $0.runtime.maxTurnDuration = Double(value) }
        }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.runtime.maxTurnDuration == 100)
    }

    @Test func unrelatedFieldEditsDoNotOverwriteModelChoice() async throws {
        let store = AIKitConfigurationStore()
        try await store.set(section: .core, key: "model", value: .string("new-model"))
        await store.update { $0.core.maxTokens = 256 }
        let result = await store.snapshot()
        #expect(result.core.providerConfiguration(for: result.core.activeProvider).defaultModel == "new-model")
        #expect(result.core.maxTokens == 256)
    }

    @Test func modelCannotChangeHostPolicyWithoutAuthorization() async throws {
        let store = AIKitConfigurationStore()
        let tool = SetAIKitConfigurationTool(store: store)
        await #expect(throws: AIKitConfigurationError.self) {
            try await tool.call(arguments: .init(section: .safety, key: "piiGuardEnabled", value: false.generatedContent))
        }
        let allowed = SetAIKitConfigurationTool(store: store) { section, key in
            section == .core && key == "model"
        }
        _ = try await allowed.call(arguments: .init(section: .core, key: "model", value: .string("chosen")))
        #expect(await store.snapshot().core.providerConfiguration(for: .ark).defaultModel == "chosen")
    }

    @Test func legacyTokenJSONAndNewBreakdownRoundTrip() throws {
        let old = try JSONDecoder().decode(TokenUsage.self, from: Data(#"{"inputTokens":10,"outputTokens":4}"#.utf8))
        #expect(old.cachedInputTokens == 0)
        let value = TokenUsage(inputTokens: 10, outputTokens: 4, cachedInputTokens: 3, reasoningOutputTokens: 2)
        #expect(try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(value)) == value)
        let row = AIKitSessionUsageSummary(taskID: "t", modelName: "aggregate", durationSeconds: 1,
            roundTripCount: 1, messageCount: 2, usage: value)
        #expect(row.usage == value)
    }

    @Test func missingPromptContextIsDistinctFromEmptyContext() throws {
        let prompt = Transcript.Prompt(segments: [.text(.init(content: "hi"))])
        let missing = RenderedPrompt(prompt: prompt)
        let empty = RenderedPrompt(prompt: prompt, context: .init())
        #expect(missing.resolvedContext == nil)
        #expect(empty.resolvedContext != nil)
        #expect(missing.prompt == prompt)
    }

    @Test func invalidDeadlineThrowsInsteadOfTrapping() async {
        for budget in [Double.nan, .infinity, -1, 0] {
            let conversation = AIKitConversation(session: auditSession(MockLanguageModel(finalText: "unused")), turnPolicy: .init(deadline: budget))
            await #expect(throws: AIKitConversationError.invalidDeadline) {
                try await conversation.respond(to: "go")
            }
        }
    }
}

private final class HistoryTransitionState: Sendable { let smaller = Mutex(false) }

private struct HistoryTransitionProfile: LanguageModelSession.DynamicProfile, Sendable {
    let state: HistoryTransitionState
    let large: MockLanguageModel
    let small: MockLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        let usesSmallModel = state.smaller.withLock { $0 }
        LanguageModelSession.Profile { Instructions("Keep complete turns together.") }
            .model(usesSmallModel ? small : large)
            .historyTransform { entries in
                let promptIndices = entries.indices.filter { index in
                    if case .prompt = entries[index] { return true }
                    return false
                }
                let keep = usesSmallModel ? 2 : 4
                guard let start = promptIndices.suffix(keep).first else { return entries }
                return entries.enumerated().compactMap { index, entry in
                    if case .instructions = entry { return entry }
                    return index >= start ? entry : nil
                }
            }
    }
}

@Suite struct PresentationAndHistoryRegressionTests {
    @Test func historyTransformAdaptsOnModelTransitionWithoutDeletingHistory() async throws {
        let state = HistoryTransitionState()
        let large = MockLanguageModel(turns: (1...6).map { .init(text: "answer-\($0)") })
        let small = MockLanguageModel(finalText: "small answer")
        let session = LanguageModelSession(profile: HistoryTransitionProfile(state: state, large: large, small: small))
        let conversation = AIKitConversation(session: session)
        for index in 1...6 { _ = try await conversation.respond(to: "prompt-\(index)") }
        state.smaller.withLock { $0 = true }
        _ = try await conversation.respond(to: "smaller context")
        let request = try #require(small.receivedRequests.first)
        let prompts = request.transcript.compactMap { entry -> String? in
            if case .prompt(let prompt) = entry { return prompt.contentText }
            return nil
        }
        #expect(prompts.count <= 3)
        #expect(prompts.last == "smaller context")
        #expect(!prompts.contains("prompt-1"))
        #expect(session.transcript.contains { entry in
            if case .prompt(let prompt) = entry { return prompt.contentText == "prompt-1" }
            return false
        })
    }

    private struct RejectSecret: Guardrail {
        let id = "test.reject-secret"
        let stages: Set<GuardrailStage> = [.finalResult]
        func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
            if case .finalResult(let text) = payload, text.contains("secret") {
                return .block(reason: "rejected")
            }
            return .pass
        }
    }

    private nonisolated static func rejectedSession() -> LanguageModelSession {
        LanguageModelSession(profile: LanguageModelSession.Profile { Instructions("Help") }
            .model(MockLanguageModel(turns: [.init(text: "secret"), .init(text: "accepted")]))
            .guardrails(PolicyEngine(rails: [RejectSecret()])))
    }

    @MainActor @Test func rejectedPreservedResponseNeverReappearsOnNextTurn() async throws {
        let presenter = AIKitConversationPresenter(conversation: AIKitConversation(
            session: Self.rejectedSession(), turnPolicy: .init(transcriptErrorHandling: .preserveTranscript)))
        await presenter.send("first")
        #expect(presenter.lastError != nil)
        #expect(!presenter.lines.contains { $0.text == "secret" })
        let reopened = AIKitConversationPresenter(conversation: presenter.conversation)
        #expect(!reopened.lines.contains { $0.text == "secret" })
        await presenter.send("second")
        #expect(presenter.lines.contains { $0.text == "accepted" })
        #expect(!presenter.lines.contains { $0.text == "secret" })
        #expect(presenter.lastError == nil)
    }
}

@Suite struct InFlightValidationTests {
    private struct SuspendedRail: Guardrail {
        let id = "test.suspended-final-rail"
        let stages: Set<GuardrailStage> = [.finalResult]
        let gate: AuditGate
        func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
            await gate.wait()
            return .block(reason: "rejected")
        }
    }

    @Test func historyIsNotPublishedWhileValidationIsPending() async throws {
        let gate = AuditGate()
        let session = LanguageModelSession(profile: LanguageModelSession.Profile { Instructions("Help") }
            .model(MockLanguageModel(finalText: "unvalidated"))
            .guardrails(PolicyEngine(rails: [SuspendedRail(gate: gate)])))
        let conversation = AIKitConversation(session: session)
        let turn = Task { try await conversation.collectResponse(to: "hi") }
        while await !gate.entered { await Task.yield() }
        #expect(!conversation.validatedTranscript.contains { entry in
            if case .response = entry { return true }
            return false
        })
        await gate.open()
        await #expect(throws: LanguageModelError.self) { try await turn.value }
    }
}
