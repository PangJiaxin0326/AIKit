import Foundation
import FoundationModels
import Synchronization
import Testing
import AIToolKit
@testable import AIKitRuntime
import AIKitCore
import AIKitCapability
import AIKitSafety
import AIKitTestSupport

// MARK: - Helpers

@Generable
private struct EchoArguments {
    let text: String
}

@Generable
private struct EchoOutput {
    let echoed: String
}

private struct EchoTool: Tool {
    var name: String { "echo" }
    var description: String { "Echo the text back." }

    func call(arguments: EchoArguments) async throws -> EchoOutput {
        EchoOutput(echoed: arguments.text)
    }
}

/// Parks the turn until the test releases it, so overlap behavior can be
/// observed mid-flight.
private struct ParkingTool: Tool {
    var name: String { "park" }
    var description: String { "Wait for the test to release the turn." }

    let gate: ParkingGate

    func call(arguments: EchoArguments) async throws -> EchoOutput {
        await gate.wait()
        return EchoOutput(echoed: arguments.text)
    }
}

/// Hangs cancellably — the deadline race cancels the session call, and the
/// group can only unwind if the hung tool observes that cancellation.
private struct SleepingTool: Tool {
    var name: String { "park" }
    var description: String { "Sleep well past any test deadline." }

    func call(arguments: EchoArguments) async throws -> EchoOutput {
        try await Task.sleep(for: .seconds(60))
        return EchoOutput(echoed: arguments.text)
    }
}

private actor ParkingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}

private func makeProfileSession(
    model: MockLanguageModel,
    tools: [any Tool] = [],
    history: [Transcript.Entry] = []
) -> LanguageModelSession {
    LanguageModelSession(
        profile: LanguageModelSession.Profile {
            Instructions("Assist the user.")
            tools
        }
        .model(model),
        history: history
    )
}

private let transientError = LanguageModelError.rateLimited(
    .init(resetDate: nil, debugDescription: "429")
)

// MARK: - Phase 2: one session per conversation

@Suite struct ConversationSessionTests {
    /// Sequential prompts share the one official session: the second turn's
    /// request carries the first turn's prompt and response.
    @Test func sequentialTurnsSeeThePriorHistory() async throws {
        let model = MockLanguageModel(turns: [
            .init(text: "One."),
            .init(text: "Two."),
        ])
        let conversation = AIKitConversation(session: makeProfileSession(model: model))

        let first = try await conversation.respond(to: "first question")
        #expect(first.content == "One.")
        let second = try await conversation.respond(to: "second question")
        #expect(second.content == "Two.")

        let request = try #require(model.receivedRequests.last)
        let promptTexts = request.transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.contentText
        }
        #expect(promptTexts == ["first question", "second question"])
        let sawFirstAnswer = request.transcript.contains { entry in
            guard case .response(let response) = entry else { return false }
            return response.contentText == "One."
        }
        #expect(sawFirstAnswer)
    }

    /// A persisted conversation rehydrates into a new session via the
    /// official `history:` — the model sees the restored turns.
    @Test func rehydratedHistoryReachesTheModel() async throws {
        let history: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "old question")),
            ])),
            .response(Transcript.Response(assetIDs: [], segments: [
                .text(Transcript.TextSegment(content: "old answer")),
            ])),
        ]
        let model = MockLanguageModel(finalText: "With context.")
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model, history: history)
        )

        _ = try await conversation.respond(to: "follow-up")

        let request = try #require(model.receivedRequests.last)
        let sawOldAnswer = request.transcript.contains { entry in
            guard case .response(let response) = entry else { return false }
            return response.contentText == "old answer"
        }
        #expect(sawOldAnswer)
    }

    /// Independent conversations run concurrently — separate sessions,
    /// separate transcripts, no cross-talk.
    @Test func independentConversationsRunConcurrently() async throws {
        let modelA = MockLanguageModel(finalText: "A")
        let modelB = MockLanguageModel(finalText: "B")
        let a = AIKitConversation(session: makeProfileSession(model: modelA))
        let b = AIKitConversation(session: makeProfileSession(model: modelB))

        async let responseA = a.respond(to: "to A")
        async let responseB = b.respond(to: "to B")
        let (fromA, fromB) = try await (responseA, responseB)

        #expect(fromA.content == "A")
        #expect(fromB.content == "B")
        #expect(modelA.receivedRequests.count == 1)
        #expect(modelB.receivedRequests.count == 1)
    }

    /// `.serialize` queues an overlapping send behind the in-flight turn —
    /// both complete, in order, on the one session.
    @Test func serializePolicyQueuesOverlappingSends() async throws {
        let model = MockLanguageModel(turns: [
            .init(text: "One."),
            .init(text: "Two."),
        ])
        let conversation = AIKitConversation(session: makeProfileSession(model: model))

        async let first = conversation.respond(to: "first")
        async let second = conversation.respond(to: "second")
        let contents = try await Set([first.content, second.content])

        #expect(contents == ["One.", "Two."])
        #expect(model.receivedRequests.count == 2)
        // The later request carries the earlier completed turn — proof the
        // two never overlapped on the session.
        let last = try #require(model.receivedRequests.last)
        let answers = last.transcript.filter { entry in
            if case .response = entry { return true } else { return false }
        }
        #expect(answers.count == 1)
    }

    /// `.reject` refuses an overlapping send while a turn is in flight.
    @Test func rejectPolicyThrowsOnOverlap() async throws {
        let gate = ParkingGate()
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "park", argumentsJSON: #"{"text":"hi"}"#
            )]),
            .init(text: "Done."),
        ])
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model, tools: [ParkingTool(gate: gate)]),
            turnPolicy: AIKitTurnPolicy(overlap: .reject)
        )

        let firstTurn = Task { try await conversation.respond(to: "long job") }
        // Wait until the first turn is actually parked inside its tool.
        while model.receivedRequests.isEmpty {
            await Task.yield()
        }

        await #expect(throws: AIKitConversationError.overlappingTurn) {
            _ = try await conversation.respond(to: "impatient second")
        }

        await gate.open()
        let first = try await firstTurn.value
        #expect(first.content == "Done.")
    }
}

// MARK: - Phase 4: host policies around the official session

@Suite struct ConversationPolicyTests {
    /// A transient failure retries on the SAME session; the configured
    /// `.revertTranscript` policy leaves the failed attempt out of the
    /// transcript, so the retry sees a clean history.
    @Test func transientFailureRetriesOnTheSameSession() async throws {
        let model = MockLanguageModel(results: [
            .failure(transientError),
            .success(.init(text: "Recovered.")),
        ])
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model),
            turnPolicy: AIKitTurnPolicy(retry: RetryPolicy(maxAttempts: 2, backoff: .none)),
            usageRecorder: recorder,
            usageLabels: .init(modelID: "mock", providerName: "Mock")
        )

        let turn = try await conversation.respond(to: "flaky ask")

        #expect(turn.content == "Recovered.")
        #expect(model.receivedRequests.count == 2)
        // One durable record for the turn, marked completed.
        let summaries = await recorder.all()
        #expect(summaries.count == 1)
        #expect(summaries.first?.outcome == .completed)
        // The rolled-back attempt left no residue in the transcript.
        let prompts = conversation.session.transcript.filter { entry in
            if case .prompt = entry { return true } else { return false }
        }
        #expect(prompts.count == 1)
    }

    /// A guardrail violation never retries, and the terminal outcome is a
    /// failure record.
    @Test func guardrailViolationsNeverRetry() async throws {
        struct BlockEveryPrompt: Guardrail {
            let id = "test.blockPrompt"
            let stages: Set<GuardrailStage> = [.prePrompt]
            func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
                .block(reason: "closed")
            }
        }
        let model = MockLanguageModel(turns: [
            .init(text: "never"), .init(text: "never either"),
        ])
        let session = LanguageModelSession(
            profile: LanguageModelSession.Profile {
                Instructions("Assist the user.")
            }
            .model(model)
            .guardrails(PolicyEngine(rails: [BlockEveryPrompt()]))
        )
        let conversation = AIKitConversation(
            session: session,
            turnPolicy: AIKitTurnPolicy(retry: RetryPolicy(maxAttempts: 3, backoff: .none))
        )

        do {
            _ = try await conversation.respond(to: "hi")
            Issue.record("expected a throw")
        } catch let error as LanguageModelError {
            guard case .guardrailViolation = error else {
                Issue.record("expected guardrailViolation, got \(error)")
                return
            }
        }
        #expect(model.receivedRequests.isEmpty)
    }

    /// The model's `reportFailure` bail-out surfaces as a raw `TurnRefusal`,
    /// records `.refused`, and never retries.
    @Test func reportFailureSurfacesAsRefusal() async throws {
        let model = MockLanguageModel(turns: [
            .init(
                toolCalls: [.init(
                    id: "t1", name: "reportFailure",
                    argumentsJSON: #"{"reason":"too vague to file"}"#
                )],
                inputTokens: 5, outputTokens: 1
            ),
            .init(text: "never reached"),
        ])
        let session = LanguageModelSession(
            profile: LanguageModelSession.Profile {
                Instructions("Assist the user.")
                [ReportFailureTool() as any Tool]
            }
            .model(model)
            .refusalEscapeHatch()
        )
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(
            session: session,
            turnPolicy: AIKitTurnPolicy(retry: RetryPolicy(maxAttempts: 3, backoff: .none)),
            usageRecorder: recorder,
            usageLabels: .init(modelID: "mock")
        )

        do {
            _ = try await conversation.respond(to: "do the vague thing")
            Issue.record("expected a refusal")
        } catch let refusal as TurnRefusal {
            #expect(refusal.reason == "too vague to file")
        }
        #expect(model.receivedRequests.count == 1)
        let summaries = await recorder.all()
        #expect(summaries.first?.outcome == .refused)
    }

    /// The escape hatch outranks a strict allowlist when applied BEFORE the
    /// guardrails modifier (hooks run in application order) — an allowlist
    /// that (correctly) omits `reportFailure` cannot block the bail-out.
    @Test func escapeHatchOutranksTheAllowlist() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "reportFailure",
                argumentsJSON: #"{"reason":"cannot do this"}"#
            )]),
        ])
        let session = LanguageModelSession(
            profile: LanguageModelSession.Profile {
                Instructions("Assist the user.")
                [ReportFailureTool() as any Tool]
            }
            .model(model)
            .refusalEscapeHatch()
            .guardrails(PolicyEngine(rails: [AllowlistedTools(allowed: ["echo"])]))
        )
        let conversation = AIKitConversation(session: session)

        do {
            _ = try await conversation.respond(to: "vague ask")
            Issue.record("expected a refusal")
        } catch let refusal as TurnRefusal {
            #expect(refusal.reason == "cannot do this")
        } catch {
            Issue.record("expected TurnRefusal, got \(error)")
        }
    }

    /// The wall-clock deadline interrupts a hung tool mid-turn.
    @Test func deadlineInterruptsAHungTool() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "park", argumentsJSON: #"{"text":"forever"}"#
            )]),
            .init(text: "never reached"),
        ])
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model, tools: [SleepingTool()]),
            turnPolicy: AIKitTurnPolicy(deadline: 0.2)
        )

        await #expect(throws: TurnDeadlineExceeded.self) {
            _ = try await conversation.respond(to: "hang")
        }
    }

    /// Usage deltas: each turn's durable record carries THAT turn's tokens,
    /// computed from official cumulative usage, not the running total.
    @Test func usageRecordsCarryPerTurnDeltas() async throws {
        let model = MockLanguageModel(turns: [
            .init(text: "One.", inputTokens: 10, outputTokens: 2),
            .init(text: "Two.", inputTokens: 30, outputTokens: 4),
        ])
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model),
            usageRecorder: recorder,
            usageLabels: .init(modelID: "mock-model", providerName: "Mock")
        )

        _ = try await conversation.respond(to: "first")
        _ = try await conversation.respond(to: "second")

        let summaries = await recorder.all()
        #expect(summaries.count == 2)
        #expect(summaries.first?.usage == TokenUsage(inputTokens: 10, outputTokens: 2))
        #expect(summaries.last?.usage == TokenUsage(inputTokens: 30, outputTokens: 4))
        #expect(summaries.allSatisfy { $0.modelName == "mock-model" })
        #expect(summaries.allSatisfy { $0.outcome == .completed })
        #expect(summaries.allSatisfy { $0.roundTripCount == 1 })
    }

    /// A terminal failure still records the tokens the failed attempts
    /// consumed.
    @Test func failedTurnsRetainConsumedUsage() async throws {
        let model = MockLanguageModel(results: [
            .success(.init(
                text: "",
                toolCalls: [.init(id: "t1", name: "explode", argumentsJSON: "{}")],
                inputTokens: 7, outputTokens: 3
            )),
        ])
        struct ExplodingTool: Tool {
            var name: String { "explode" }
            var description: String { "Always fails." }
            func call(arguments: EchoArguments) async throws -> EchoOutput {
                throw GenericToolError(message: "boom", isRetriable: false)
            }
        }
        let recorder = InMemorySessionUsageStore()
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model, tools: [ExplodingTool()]),
            turnPolicy: AIKitTurnPolicy(retry: RetryPolicy(maxAttempts: 1, backoff: .none)),
            usageRecorder: recorder,
            usageLabels: .init(modelID: "mock")
        )

        await #expect(throws: (any Error).self) {
            _ = try await conversation.respond(to: "explode please")
        }

        let summaries = await recorder.all()
        #expect(summaries.count == 1)
        #expect(summaries.first?.outcome == .failed)
        #expect(summaries.first?.usage == TokenUsage(inputTokens: 7, outputTokens: 3))
    }
}

// MARK: - Phase 3: activity store

@Suite struct ActivityStoreTests {
    @Test func conversationTurnsDriveTheBusyState() async throws {
        let gate = ParkingGate()
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "park", argumentsJSON: #"{"text":"hi"}"#
            )]),
            .init(text: "Done."),
        ])
        let store = AIKitActivityStore()
        let conversation = AIKitConversation(
            session: makeProfileSession(model: model, tools: [ParkingTool(gate: gate)]),
            activity: store,
            activityLabel: "Filing…"
        )

        let turn = Task { try await conversation.respond(to: "go") }
        while await !store.snapshot().isBusy {
            await Task.yield()
        }
        let busy = await store.snapshot()
        #expect(busy.statusText == "Filing…")

        await gate.open()
        _ = try await turn.value
        let idle = await store.snapshot()
        #expect(!idle.isBusy)
        #expect(idle.items.isEmpty)
    }

    @Test func externalWorkAndCancelAllReachEverything() async throws {
        let store = AIKitActivityStore()
        let cancelled = Mutex<[String]>([])

        let workID = await store.begin("Exporting…") {
            cancelled.withLock { $0.append("export") }
        }
        #expect(await store.snapshot().statusText == "Exporting…")

        await store.update(workID, label: "Uploading…")
        #expect(await store.snapshot().statusText == "Uploading…")

        await store.cancelAll()
        #expect(cancelled.withLock { $0 } == ["export"])
        #expect(await store.snapshot().isBusy)
        await store.end(workID)
        #expect(await !store.snapshot().isBusy)
    }

    @Test func guardrailWarningsLandInTheStore() async throws {
        let store = AIKitActivityStore()
        let model = MockLanguageModel(finalText: "Sure.")
        let session = LanguageModelSession(
            profile: LanguageModelSession.Profile {
                Instructions("Assist the user.")
            }
            .model(model)
            .guardrails(PolicyEngine(rails: [InjectionSniffer()]), activity: store)
        )
        let conversation = AIKitConversation(session: session)

        _ = try await conversation.respond(to: "jailbreak everything")

        // The sink hops onto the store's executor; give it a beat.
        var warnings: [GuardrailWarning] = []
        for _ in 0..<200 {
            warnings = await store.snapshot().warnings
            if !warnings.isEmpty { break }
            await Task.yield()
        }
        #expect(warnings.count == 1)
        #expect(warnings.first?.railID == "builtin.injectionSniffer")
    }
}
