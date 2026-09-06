import Foundation
import FoundationModels
import Synchronization
import AIKitCore
import AIKitCapability
import AIKitSafety

/// Compatibility name for the official, conditionally Sendable response.
@available(*, deprecated, renamed: "LanguageModelSession.Response")
public typealias AIKitTurnResponse = LanguageModelSession.Response<String>

/// Host policies around one official session. All policy-governed operations
/// use `withTurn`: FIFO admission, cancellation, cooperative deadline, retry,
/// activity, and shielded usage settlement. The session owns model execution.
/// Direct calls to `session` deliberately bypass these policies.
public actor AIKitConversation {
    private final class Visibility: Sendable {
        let acceptedEntryIDs = Mutex<Set<String>>([])
    }
    private nonisolated let visibility = Visibility()

    /// The official history filtered by this boundary's acceptance decisions.
    /// Use this for presentation and rehydration: preserved failed responses
    /// remain in the raw session for host recovery, but are not accepted output.
    /// Initial history passed by a host is assumed to have been validated.
    public nonisolated var validatedTranscript: Transcript {
        let accepted = visibility.acceptedEntryIDs.withLock { $0 }
        return Transcript(entries: session.transcript.filter { accepted.contains($0.id) })
    }

    /// Labels durable usage records carry — the session API has no notion
    /// of a model id or provider display name. For profiles that switch models,
    /// use an aggregate label; these totals are not per-provider billing data.
    public struct UsageLabels: Sendable {
        public var modelID: String
        public var providerName: String?

        public init(modelID: String, providerName: String? = nil) {
            self.modelID = modelID
            self.providerName = providerName
        }
    }

    /// A turn's starting point for usage accounting: cumulative usage,
    /// transcript identity, and wall-clock start. `respond` takes its own;
    /// hosts driving `session.streamResponse` directly take one via
    /// `markTurnStart()` and settle with `recordTurn(from:outcome:)`.
    public struct TurnMark: Sendable {
        let usage: TokenUsage
        let entryIDs: Set<String>
        let startedAt: Date
        let measuredRounds: Int?
    }

    /// The official session — the source of truth for the transcript,
    /// streaming, `isResponding`, and cumulative usage. Direct `respond`
    /// calls on it bypass the turn policy; use the conversation's `respond`
    /// for policy-wrapped turns.
    public nonisolated let session: LanguageModelSession

    /// Without a metrics hook, round counts cover retained response entries
    /// only. Cumulative token deltas still include rolled-back attempts.
    private let metrics: AIKitTurnMetrics?
    private let turnPolicy: AIKitTurnPolicy
    private let usageRecorder: (any AIKitSessionUsageRecording)?
    private let usageLabels: UsageLabels?
    private let activity: AIKitActivityStore?
    private let activityLabel: String?
    private let errorHandler = ErrorHandler()
    private let logger = AIKitLog.runtime

    private var turnCounter = 0
    private var isTurnInFlight = false
    private var turnWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(
        session: LanguageModelSession,
        turnPolicy: AIKitTurnPolicy = AIKitTurnPolicy(),
        usageRecorder: (any AIKitSessionUsageRecording)? = nil,
        usageLabels: UsageLabels? = nil,
        activity: AIKitActivityStore? = nil,
        activityLabel: String? = nil,
        metrics: AIKitTurnMetrics? = nil
    ) {
        // Transcript rollback restores history, never external side effects.
        // Automatic replay is disabled unless the host explicitly opts in.
        session.transcriptErrorHandlingPolicy = turnPolicy.transcriptErrorHandling.official
        self.session = session
        visibility.acceptedEntryIDs.withLock { $0 = Set(session.transcript.map(\.id)) }
        self.metrics = metrics
        self.turnPolicy = turnPolicy
        self.usageRecorder = usageRecorder
        self.usageLabels = usageLabels
        self.activity = activity
        self.activityLabel = activityLabel
    }

    // MARK: - Turns

    @discardableResult
    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: GeneratedContent] = [:]
    ) async throws -> LanguageModelSession.Response<String> {
        try await respond(to: Prompt { prompt }, options: options,
                          contextOptions: contextOptions, metadata: metadata)
    }

    @discardableResult
    public func respond(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: GeneratedContent] = [:]
    ) async throws -> LanguageModelSession.Response<String> {
        try await withTurn { session in
            try await session.respond(to: prompt, options: options,
                                      contextOptions: contextOptions, metadata: metadata)
        }
    }

    @discardableResult
    public func respond<Content: Generable & Sendable>(
        to prompt: Prompt,
        generating type: Content.Type,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
        metadata: [String: GeneratedContent] = [:]
    ) async throws -> LanguageModelSession.Response<Content> {
        try await withTurn { session in
            try await session.respond(to: prompt, generating: type, options: options,
                                      contextOptions: contextOptions, metadata: metadata)
        }
    }

    @discardableResult
    public func respond(
        to prompt: Prompt,
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
        metadata: [String: GeneratedContent] = [:]
    ) async throws -> LanguageModelSession.Response<GeneratedContent> {
        try await withTurn { session in
            try await session.respond(to: prompt, schema: schema, options: options,
                                      contextOptions: contextOptions, metadata: metadata)
        }
    }

    /// Consumes the native stream, releasing its result only after every
    /// profile hook succeeds. Native snapshots are provisional: `onResponse`
    /// may reject text already emitted by the framework. This validated path
    /// intentionally buffers them. Use `withTurn` for explicitly provisional
    /// streaming only when the host accepts that disclosure contract.
    public func collectResponse(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<String> {
        try await withTurn { session in
            try await session.streamResponse(to: prompt, options: options).collect()
        }
    }

    /// Escape hatch for official SDK operations (including custom typed or
    /// streaming operations) under the same lifecycle. An explicit retry
    /// policy promises the operation and all its tools are safe to repeat.
    /// Do not return before the session operation has finished.
    public func withTurn<Result: Sendable>(
        _ operation: @escaping @Sendable (LanguageModelSession) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        if let budget = turnPolicy.deadline, !budget.isFinite || budget <= 0 {
            throw AIKitConversationError.invalidDeadline
        }
        try await acquireTurnSlot()
        turnCounter += 1
        let number = turnCounter
        let mark = markTurnStart()
        let deadline = turnPolicy.deadline.map { ContinuousClock.now.advanced(by: .seconds($0)) }
        // The owned task gives the activity store a real cancellation handle.
        // Cancellation of the caller is explicitly forwarded, and settlement
        // waits for cooperative execution to finish before releasing the slot.
        let task = Task { try await self.performTurn(deadline: deadline, operation) }
        let activityID = await activity?.begin(activityLabel, onCancel: { task.cancel() })
        var outcome = AIKitSessionUsageOutcome.failed
        defer {
            await withTaskCancellationShield {
                await self.persistTurn(number: number, from: mark, outcome: outcome)
                if let activityID { await self.activity?.end(activityID) }
                self.releaseTurnSlot()
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
            }
            let currentIDs = Set(session.transcript.map(\.id))
            visibility.acceptedEntryIDs.withLock {
                $0.formIntersection(currentIDs)
                $0.formUnion(currentIDs.subtracting(mark.entryIDs))
            }
            outcome = .completed
            return result
        } catch {
            let cause = ErrorClassifier.underlyingError(error)
            if Task.isCancelled || cause is CancellationError {
                outcome = .cancelled
                throw CancellationError()
            }
            if cause is TurnRefusal { outcome = .refused }
            throw cause
        }
    }

    private func performTurn<Result: Sendable>(
        deadline: ContinuousClock.Instant?,
        _ operation: @escaping @Sendable (LanguageModelSession) async throws -> Result
    ) async throws -> Result {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let result = try await withDeadline(deadline) { [session] in
                    let result = try await operation(session)
                    try Task.checkCancellation()
                    return result
                }
                return result
            } catch {
                let cause = ErrorClassifier.underlyingError(error)
                if Task.isCancelled || cause is CancellationError { throw CancellationError() }
                if cause is TurnRefusal { throw cause }
                attempt += 1
                let decision = await errorHandler.handle(cause, attempt: attempt, policy: turnPolicy.retry)
                switch decision {
                case .abort(let cause): throw cause
                case .retry(let delay):
                    // Preserved history requires a host repair before replay.
                    if turnPolicy.transcriptErrorHandling == .preserveTranscript,
                       turnPolicy.prepareForRetry == nil { throw cause }
                    try await withDeadline(deadline) { [session, turnPolicy] in
                        if let prepare = turnPolicy.prepareForRetry { try await prepare(session) }
                        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    }
                }
            }
        }
    }

    /// Accounting-only escape hatch. Prefer `withTurn` for admission,
    /// cancellation, deadlines and settlement; do not overlap direct calls.
    @available(*, deprecated, message: "Use withTurn or collectResponse for policy-governed operations.")
    public func recordTurn(from mark: TurnMark, outcome: AIKitSessionUsageOutcome) async {
        turnCounter += 1
        await withTaskCancellationShield {
            await self.persistTurn(number: self.turnCounter, from: mark, outcome: outcome)
        }
    }

    public func markTurnStart() -> TurnMark {
        TurnMark(usage: TokenUsage(session.usage),
                 entryIDs: Set(session.transcript.map(\.id)), startedAt: Date(),
                 measuredRounds: metrics?.roundTripCount)
    }

    // MARK: - Usage persistence

    private func persistTurn(
        number: Int,
        from mark: TurnMark,
        outcome: AIKitSessionUsageOutcome
    ) async {
        guard let usageRecorder else { return }
        let current = TokenUsage(session.usage)
        let delta = TokenUsage(
            inputTokens: max(0, current.inputTokens - mark.usage.inputTokens),
            outputTokens: max(0, current.outputTokens - mark.usage.outputTokens),
            cachedInputTokens: max(0, current.cachedInputTokens - mark.usage.cachedInputTokens),
            reasoningOutputTokens: max(0, current.reasoningOutputTokens - mark.usage.reasoningOutputTokens)
        )
        // Failed and cancelled turns are recorded when they consumed tokens
        // (the migration contract); a turn blocked before the model ran
        // leaves no record.
        guard outcome == .completed || delta != .zero else { return }

        let added = session.transcript.filter { !mark.entryIDs.contains($0.id) }
        let retainedRounds = added.count { entry in
            switch entry {
            case .response: true
            default: false
            }
        }
        let endedAt = Date()
        let summary = AIKitSessionUsageSummary(
            taskID: "conversation-turn-\(number)-\(UUID().uuidString)",
            modelName: usageLabels?.modelID ?? "unknown-model",
            providerName: usageLabels?.providerName,
            startedAt: mark.startedAt,
            endedAt: endedAt,
            durationSeconds: endedAt.timeIntervalSince(mark.startedAt),
            roundTripCount: mark.measuredRounds.map { max(0, (metrics?.roundTripCount ?? $0) - $0) } ?? retainedRounds,
            messageCount: added.count,
            usage: delta,
            outcome: outcome
        )
        do {
            try await usageRecorder.record(summary)
        } catch {
            logger.error("Failed to persist AIKit conversation usage")
        }
    }

    // MARK: - Overlap policy

    private func acquireTurnSlot() async throws {
        try Task.checkCancellation()
        if !isTurnInFlight {
            isTurnInFlight = true
            return
        }
        guard turnPolicy.overlap == .serialize else {
            throw AIKitConversationError.overlappingTurn
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { turnWaiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // releaseTurnSlot handed this caller the slot, even if cancellation
        // raced the handoff. Release it before propagating that cancellation.
        if Task.isCancelled {
            releaseTurnSlot()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = turnWaiters.firstIndex(where: { $0.id == id }) else { return }
        turnWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseTurnSlot() {
        if turnWaiters.isEmpty { isTurnInFlight = false }
        else { turnWaiters.removeFirst().continuation.resume() }
    }

    // MARK: - Deadline

    /// Races `operation` against the turn deadline. The timer firing first
    /// throws `TurnDeadlineExceeded` and cancels the in-flight session call,
    /// and waits for cooperative cleanup. A noncooperative tool can delay
    /// settlement; Swift cancellation cannot forcibly terminate arbitrary work.
    private func withDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let deadline else { return try await operation() }
        let budget = turnPolicy.deadline ?? 0
        guard ContinuousClock.now < deadline else { throw TurnDeadlineExceeded(budget: budget) }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: ContinuousClock())
                throw TurnDeadlineExceeded(budget: budget)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TurnDeadlineExceeded(budget: budget)
            }
            return result
        }
    }
}
