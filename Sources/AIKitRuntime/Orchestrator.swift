import Foundation
import FoundationModels
import OSLog
import AIToolKit
import AIKitCore
import AIKitCapability
import AIKitSafety

/// Events streamed to the host for one turn.
///
/// Deprecated with `Orchestrator` (removal follows the deprecation
/// window): text rides `ResponseStream.Snapshot.content`, tool calls and
/// outputs ride profile lifecycle hooks and `Transcript.Entry` values,
/// warnings ride `GuardrailActivitySink`, and refusals throw `TurnRefusal`.
public enum OrchestratorEvent: Sendable {
    case promptBuilt(RenderedPrompt)
    case llmDelta(String)
    /// The model's reasoning / chain-of-thought for the turn. The session
    /// surface exposes reasoning through transcript entries, so this is
    /// emitted once per model call, after the call completes. Never emitted
    /// when the model produced no reasoning.
    case reasoningDelta(String)
    /// A tool call about to execute, as the official transcript entry —
    /// real call id included. Arguments are `call.arguments` (JSON via
    /// `jsonString`).
    case toolCall(Transcript.ToolCall)
    /// An executed tool call and its official output entry. Render the
    /// output with `Transcript.ToolOutput.contentText`.
    case toolResult(Transcript.ToolCall, Transcript.ToolOutput)
    case verification(stage: GuardrailStage, outcome: GuardrailOutcome)
    /// Token usage for one attempt, summed over every model call the
    /// session made — tool rounds included. Read from the per-attempt
    /// session's lifetime usage, because `Response.usage` carries only the
    /// final model call of a turn. Emitted once per attempt (failed and
    /// cancelled attempts included, when they consumed tokens) so hosts can
    /// do cost/telemetry accounting even on the streaming path; sum the
    /// events, never overwrite.
    case usage(TokenUsage)
    case finalAnswer(String)
    /// The turn ended without completing the request — either the model
    /// called `reportFailure` (a vague / unexecutable ask) or a terminal
    /// error was mapped to a user-facing reason.
    case failure(reason: String)
    case error(any Error)
}

/// A UI-friendly snapshot of the runtime state the orchestrator already owns.
public struct OrchestratorSnapshot: Sendable, Hashable {
    public var contexts: [ViewContext]
    public var resolvedContext: ResolvedContext
    public var availableTools: [ToolDescriptor]
    public var recentActivities: [UsageEvent]
    public var recentTasks: [OrchestratorTaskSnapshot]

    public init(
        contexts: [ViewContext],
        resolvedContext: ResolvedContext,
        availableTools: [ToolDescriptor],
        recentActivities: [UsageEvent],
        recentTasks: [OrchestratorTaskSnapshot] = []
    ) {
        self.contexts = contexts
        self.resolvedContext = resolvedContext
        self.availableTools = availableTools
        self.recentActivities = recentActivities
        self.recentTasks = recentTasks
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contexts == rhs.contexts
            && lhs.resolvedContext == rhs.resolvedContext
            && lhs.availableTools.aikitSnapshotSignature == rhs.availableTools.aikitSnapshotSignature
            && lhs.recentActivities == rhs.recentActivities
            && lhs.recentTasks == rhs.recentTasks
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(contexts)
        hasher.combine(resolvedContext)
        hasher.combine(availableTools.aikitSnapshotSignature)
        hasher.combine(recentActivities)
        hasher.combine(recentTasks)
    }
}

private struct ToolDescriptorSnapshotSignature: Sendable, Hashable {
    var name: String
    var description: String
    var argumentsSchema: String
    var outputSchema: String?
}

private extension Array where Element == ToolDescriptor {
    var aikitSnapshotSignature: [ToolDescriptorSnapshotSignature] {
        map { descriptor in
            ToolDescriptorSnapshotSignature(
                name: descriptor.name,
                description: descriptor.description,
                argumentsSchema: (try? descriptor.argumentsSchema.jsonString())
                    ?? descriptor.argumentsSchema.debugDescription,
                outputSchema: descriptor.outputSchema.map {
                    (try? $0.jsonString()) ?? $0.debugDescription
                }
            )
        }
    }
}

/// What the orchestrator is doing right now, for a single turn. Aggregated
/// across all in-flight turns by `OrchestratorActivity`.
public enum OrchestratorPhase: Sendable, Equatable, Hashable {
    /// No turn is using this slot.
    case idle
    /// Building the prompt / running pre-prompt guardrails.
    case preparing
    /// Waiting on / streaming from the model.
    case thinking
    /// Executing the named tool.
    case callingTool(String)
    /// Running a verification (guardrail) stage on a result.
    case verifying
    /// Host-run work outside the orchestrator's own loop (e.g. a scoped
    /// workflow session), carrying its own user-facing status text. `nil`
    /// until the host resolves one — UI shows its generic busy label.
    case externalWork(String?)
}

/// A single user task as seen by the orchestrator, with its grouped activity
/// events and model usage. Active snapshots have `endedAt == nil`; call
/// `duration(at:)` with the current clock tick to display a live elapsed time.
public struct OrchestratorTaskSnapshot: Sendable, Identifiable, Hashable {
    public let id: Int
    public let instruction: String
    public let startedAt: Date
    public let endedAt: Date?
    public let phase: OrchestratorPhase
    public let failureReason: String?
    public let usage: TokenUsage
    public let activities: [UsageEvent]

    public var isRunning: Bool { endedAt == nil }

    public init(
        id: Int,
        instruction: String,
        startedAt: Date,
        endedAt: Date? = nil,
        phase: OrchestratorPhase,
        failureReason: String? = nil,
        usage: TokenUsage = .zero,
        activities: [UsageEvent] = []
    ) {
        self.id = id
        self.instruction = instruction
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.phase = phase
        self.failureReason = failureReason
        self.usage = usage
        self.activities = activities
    }

    public func duration(at date: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? date).timeIntervalSince(startedAt))
    }
}

/// A `Sendable` snapshot of what an `Orchestrator` is doing. Delivered live
/// via `Orchestrator.activityUpdates()` so UI can reflect any turn on the
/// instance — including overlapping ones — regardless of which session
/// started it.
public struct OrchestratorActivity: Sendable, Equatable {
    /// Turns currently in flight (overlapping `run` calls).
    public let activeTurns: Int
    /// The most user-visible phase across in-flight turns: a tool call
    /// outranks thinking so it stays visible while another turn streams.
    public let phase: OrchestratorPhase
    /// The reason the most recent turn failed, if any. Sticky: it persists
    /// after the turn ends until a new `run` starts or `cancelActiveTurns()`
    /// is called, so UI can surface it.
    public let failureReason: String?
    /// Per-turn live task snapshots, including elapsed-time anchors and usage
    /// accumulated so far. Kept separate from the aggregate `phase` so UI can
    /// render overlapping tasks individually.
    public let activeTasks: [OrchestratorTaskSnapshot]

    public var isBusy: Bool { activeTurns > 0 }
    public var hasFailed: Bool { failureReason != nil }

    /// A short, user-facing description of the current state.
    public var statusText: String {
        if isBusy {
            switch phase {
            case .idle, .preparing: return "Preparing…"
            case .thinking: return "Thinking…"
            case .callingTool(let name): return "Calling \(name)…"
            case .verifying: return "Checking the result…"
            case .externalWork(let status): return status ?? "Thinking…"
            }
        }
        if let failureReason { return failureReason }
        return "Idle"
    }

    public static let idle = OrchestratorActivity(
        activeTurns: 0, phase: .idle, failureReason: nil, activeTasks: []
    )

    /// Higher rank wins when aggregating concurrent turns into one `phase`.
    static func rank(_ phase: OrchestratorPhase) -> Int {
        switch phase {
        case .idle: 0
        case .preparing: 1
        case .verifying: 2
        case .thinking: 3
        case .callingTool: 4
        // External work carries the most specific user-facing label (the
        // workflow's resolved finishing-tool text), so it wins the aggregate.
        case .externalWork: 5
        }
    }
}

private struct OrchestratorTaskRecord: Sendable {
    let id: Int
    let instruction: String
    let usageRecordID: UUID
    let usageTaskID: String
    let startedAt: Date
    var viewID: ViewContext.ID?
    var endedAt: Date?
    var phase: OrchestratorPhase
    var failureReason: String?
    var usage = TokenUsage.zero
    var roundTripCount = 0
    var activities: [UsageEvent] = []

    var snapshot: OrchestratorTaskSnapshot {
        OrchestratorTaskSnapshot(
            id: id,
            instruction: instruction,
            startedAt: startedAt,
            endedAt: endedAt,
            phase: phase,
            failureReason: failureReason,
            usage: usage,
            activities: activities
        )
    }

    func duration(at date: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? date).timeIntervalSince(startedAt))
    }

    func messageCount(outcome: AIKitSessionUsageOutcome) -> Int {
        // Every recorded activity is one transcript message: the user
        // instruction, each tool call and each tool result, and the final
        // model response (or error). The tool messages are what make a
        // multi-round-trip turn read as more than the 2 of a plain chat turn,
        // so they count too — excluding them pinned every tool-using turn at 2.
        let activityMessageCount = activities.count
        let hasUserInstruction = activities.contains { $0.kind == .userInstruction }
        let hasTerminalAssistantMessage = activities.contains {
            $0.kind == .llmResponse || $0.kind == .error
        }
        let userMessageCount = hasUserInstruction ? activityMessageCount : activityMessageCount + 1
        if !hasTerminalAssistantMessage,
           outcome == .failed || outcome == .refused {
            return userMessageCount + 1
        }
        return userMessageCount
    }

    func usageSummary(
        modelName: String,
        providerName: String?,
        outcome: AIKitSessionUsageOutcome
    ) -> AIKitSessionUsageSummary {
        let endedAt = endedAt ?? Date()
        return AIKitSessionUsageSummary(
            id: usageRecordID,
            taskID: usageTaskID,
            modelName: modelName,
            providerName: providerName,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration(at: endedAt),
            roundTripCount: roundTripCount,
            messageCount: messageCount(outcome: outcome),
            usage: usage,
            outcome: outcome,
            recordedAt: Date()
        )
    }
}

/// The model a turn runs on — any official `LanguageModel` conformance —
/// plus the labels usage records carry. Built from an `AIKitLanguageModel`
/// (the shipped models) or from any other conformance.
///
/// Deprecated with `Orchestrator`: the model belongs on the profile
/// (`.model(_:)`) and the labels on `AIKitConversation.UsageLabels`.
public struct OrchestratorModel: Sendable {
    public let modelID: String
    public let providerName: String?
    let model: any LanguageModel

    /// Any official `LanguageModel`.
    @available(*, deprecated, message: "Apply the model to the profile with `.model(_:)`; usage-record labels move to AIKitConversation.UsageLabels.")
    public init(
        model: some LanguageModel,
        modelID: String,
        providerName: String? = nil
    ) {
        self.modelID = modelID
        self.providerName = providerName
        self.model = model
    }

    /// The non-deprecated seam the pinned legacy-behavior tests construct
    /// through while the public initializers carry deprecation warnings.
    internal init(
        testing model: any LanguageModel,
        modelID: String,
        providerName: String? = nil
    ) {
        self.modelID = modelID
        self.providerName = providerName
        self.model = model
    }


}

/// The single entry point a host app calls once per user instruction. An actor
/// so concurrent `run` calls on one instance serialize cleanly.
///
/// **Deprecated.** The model pipeline belongs to the official session: build
/// a `DynamicProfile` (model, generation options, `.guardrails(_:)`,
/// `.refusalEscapeHatch()`) and drive it with `LanguageModelSession(profile:)`
/// — or `AIKitConversation` when retry/deadline/usage policies are needed.
/// The initializers carry the deprecation; the README's migration table maps
/// every member to its replacement. This type is removed after the
/// deprecation window.
///
/// Each turn runs in one official `LanguageModelSession`, built as a
/// `DynamicProfile` over the configured model: the session executes tools
/// natively and owns the in-turn transcript, and AIKit's tool guardrails run
/// inside it through the official `onToolCall`/`onToolOutput` hooks. The
/// orchestrator contributes what the session API does not — view-context
/// resolution, the prompt/final-result guardrail stages, durable memory and
/// usage records, retry/deadline policy, and the host-facing event and
/// activity streams.
public actor Orchestrator {
    public struct Options: Sendable {
        public var stream: Bool
        public var retry: RetryPolicy
        /// Cooperative execution budget for generation, guardrails and retry
        /// backoff. Swift waits for tool cleanup after requesting cancellation;
        /// a noncooperative tool can delay settlement beyond this budget.
        public var maxTurnDuration: TimeInterval?
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            stream: Bool = true,
            retry: RetryPolicy = .never,
            maxTurnDuration: TimeInterval? = nil,
            temperature: Double? = 0.2,
            maxTokens: Int? = nil
        ) {
            self.stream = stream
            self.retry = retry
            self.maxTurnDuration = maxTurnDuration
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    private let model: OrchestratorModel
    /// The host's official tools plus AIKit's built-ins, in registration
    /// order — the `[any Tool]` currency of the runtime.
    private let allTools: [any Tool]
    /// Name-indexed view over `allTools` for context-subset resolution.
    private let tools: ToolSet
    private let memory: any MemoryStore
    private let contextResolver: ContextResolver
    private let guardrails: PolicyEngine
    private let usageRecorder: (any AIKitSessionUsageRecording)?
    private let errorHandler = ErrorHandler()
    private let options: Options
    private let logger = AIKitLog.runtime

    private var turnCounter = 0
    /// Latest phase per in-flight turn id. Actor-isolated, so concurrent
    /// turns mutate it safely without any extra synchronization.
    private var turnPhases: [Int: OrchestratorPhase] = [:]
    /// The in-flight `loop` task per turn id, so a turn can be cancelled.
    private var turnTasks: [Int: Task<Void, Never>] = [:]
    /// Per-turn activity ledgers backing the overlay's task-grouped history.
    private var taskRecords: [Int: OrchestratorTaskRecord] = [:]
    /// Turn ids whose durable usage summary has already been created. Kept
    /// outside `OrchestratorTaskRecord` so UI task snapshots remain pure view
    /// state and persistence finalization stays runtime-owned.
    private var finalizedUsageTurns: Set<Int> = []
    private let maxTrackedCompletedTasks = 24
    /// Cancel callbacks for in-flight external work (see
    /// `beginExternalWork(statusText:onCancel:)`), keyed by work id, so
    /// `cancelActiveTurns()` reaches work the orchestrator does not run.
    private var externalWorkCancelHandlers: [Int: @Sendable () -> Void] = [:]
    /// Sticky reason from the last failed turn; cleared when a new turn
    /// starts or `cancelActiveTurns()` is called.
    private var lastFailureReason: String?
    private var activityObservers: [UUID: AsyncStream<OrchestratorActivity>.Continuation] = [:]
    /// Observer ids whose stream terminated before the actor processed their
    /// registration task.
    private var terminatedActivityObservers: Set<UUID> = []

    private func nextTurnID() -> Int {
        turnCounter += 1
        return turnCounter
    }

    private func startTask(_ instruction: String, turn: Int) {
        taskRecords[turn] = OrchestratorTaskRecord(
            id: turn,
            instruction: instruction,
            usageRecordID: UUID(),
            usageTaskID: "turn-\(turn)-\(UUID().uuidString)",
            startedAt: Date(),
            viewID: nil,
            endedAt: nil,
            phase: .preparing,
            failureReason: nil
        )
    }

    private func setTaskViewID(_ viewID: ViewContext.ID, turn: Int) {
        guard var record = taskRecords[turn] else { return }
        record.viewID = viewID
        taskRecords[turn] = record
    }

    private func finishTask(
        _ turn: Int,
        failureReason: String? = nil,
        outcome: AIKitSessionUsageOutcome? = nil
    ) -> AIKitSessionUsageSummary? {
        guard var record = taskRecords[turn] else { return nil }
        guard finalizedUsageTurns.insert(turn).inserted else { return nil }
        if record.endedAt == nil {
            record.endedAt = Date()
        }
        if let failureReason {
            record.failureReason = failureReason
        }
        record.phase = .idle
        let resolvedOutcome = outcome
            ?? (record.failureReason == nil ? .completed : .failed)
        let summary = record.usageSummary(
            modelName: model.modelID,
            providerName: model.providerName,
            outcome: resolvedOutcome
        )
        taskRecords[turn] = record
        trimCompletedTaskRecords()
        return summary
    }

    private func trimCompletedTaskRecords() {
        let completed = taskRecords.values
            .filter { $0.endedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }
        for record in completed.dropFirst(maxTrackedCompletedTasks) {
            taskRecords[record.id] = nil
            finalizedUsageTurns.remove(record.id)
        }
    }

    private func taskSnapshots(
        matching viewID: ViewContext.ID? = nil,
        activeOnly: Bool = false,
        limit: Int? = nil
    ) -> [OrchestratorTaskSnapshot] {
        var records = taskRecords.values.filter { record in
            if activeOnly, record.endedAt != nil { return false }
            guard let viewID else { return true }
            return record.viewID == nil || record.viewID == viewID
        }
        records.sort { lhs, rhs in
            if lhs.endedAt == nil, rhs.endedAt != nil { return true }
            if lhs.endedAt != nil, rhs.endedAt == nil { return false }
            return lhs.startedAt > rhs.startedAt
        }
        let snapshots = records.map(\.snapshot)
        guard let limit else { return snapshots }
        return Array(snapshots.prefix(max(0, limit)))
    }

    private func addUsage(_ usage: TokenUsage, turn: Int) {
        guard var record = taskRecords[turn] else { return }
        record.usage = TokenUsage(
            inputTokens: record.usage.inputTokens + usage.inputTokens,
            outputTokens: record.usage.outputTokens + usage.outputTokens,
            cachedInputTokens: record.usage.cachedInputTokens + usage.cachedInputTokens,
            reasoningOutputTokens: record.usage.reasoningOutputTokens + usage.reasoningOutputTokens
        )
        taskRecords[turn] = record
        broadcast()
    }

    fileprivate func recordModelRound(turn: Int) {
        guard var record = taskRecords[turn] else { return }
        record.roundTripCount += 1
        taskRecords[turn] = record
    }

    private func persistUsage(_ summary: AIKitSessionUsageSummary?) async {
        guard let summary, let usageRecorder else { return }
        await withTaskCancellationShield {
            do { try await usageRecorder.record(summary) }
            catch { logger.error("Failed to persist AIKit session usage") }
        }
    }

    private func appendTaskActivity(_ event: UsageEvent, turn: Int?) {
        guard let turn, var record = taskRecords[turn] else { return }
        record.activities.append(event)
        taskRecords[turn] = record
        broadcast()
    }

    private func recordActivity(
        viewID: ViewContext.ID,
        kind: UsageEvent.Kind,
        text: String,
        turn: Int? = nil
    ) async {
        let event = UsageEvent(viewID: viewID, kind: kind, text: text)
        appendTaskActivity(event, turn: turn)
        try? await memory.append(event)
    }

    // MARK: - External work

    /// Surfaces host-run work in `activityUpdates()` — work the orchestrator
    /// itself does not execute, e.g. a scoped (select-then-work) workflow
    /// session. Subscribers go busy and show `statusText`, or their generic
    /// busy label while it is `nil`. External work never appears in task
    /// snapshots or usage records; it only drives live activity.
    ///
    /// Returns the work id. Pair with `endExternalWork(_:)`, and update the
    /// label via `updateExternalWork(_:statusText:)` — e.g. the moment a
    /// workflow's scope step resolves its finishing-tool selection.
    /// `onCancel` is invoked by `cancelActiveTurns()`, so UI cancel controls
    /// reach this work too.
    public func beginExternalWork(
        statusText: String? = nil,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> Int {
        let id = nextTurnID()
        if let onCancel { externalWorkCancelHandlers[id] = onCancel }
        setPhase(.externalWork(statusText), turn: id)
        return id
    }

    /// Updates external work's user-facing status text. No-op once the work
    /// has ended or been cancelled.
    public func updateExternalWork(_ id: Int, statusText: String?) {
        guard turnPhases[id] != nil else { return }
        setPhase(.externalWork(statusText), turn: id)
    }

    /// Ends external work, returning subscribers to idle when nothing else
    /// is in flight. Idempotent.
    public func endExternalWork(_ id: Int) {
        externalWorkCancelHandlers[id] = nil
        guard turnPhases.removeValue(forKey: id) != nil else { return }
        broadcast()
    }

    /// Cancels every in-flight turn — and any registered external work, via
    /// its cancel callback — and clears any sticky failure. Activity remains
    /// busy until each owner settles. Safe to call from UI.
    public func cancelActiveTurns() async {
        for task in turnTasks.values { task.cancel() }
        let externalCancels = externalWorkCancelHandlers.values
        externalWorkCancelHandlers.removeAll()
        for cancel in externalCancels { cancel() }
        // Owners finalize usage and end their activity only after cancellation
        // settles. External owners must pair beginExternalWork with end.
        lastFailureReason = nil
        broadcast()
    }

    /// A live stream of this orchestrator's activity: the current state is
    /// emitted immediately on subscription, then again on every phase or
    /// turn-count change. Each subscriber gets an independent stream, so a
    /// floating assistant button reflects turns started anywhere — including
    /// overlapping ones — not just its own session's.
    public nonisolated func activityUpdates() -> AsyncStream<OrchestratorActivity> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task { await self.registerActivityObserver(id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterActivityObserver(id) }
            }
        }
    }

    private func registerActivityObserver(
        _ id: UUID,
        _ continuation: AsyncStream<OrchestratorActivity>.Continuation
    ) {
        guard terminatedActivityObservers.remove(id) == nil else { return }
        activityObservers[id] = continuation
        continuation.yield(currentActivity())
    }

    private func unregisterActivityObserver(_ id: UUID) {
        if activityObservers.removeValue(forKey: id) == nil {
            terminatedActivityObservers.insert(id)
        }
    }

    private func currentActivity() -> OrchestratorActivity {
        OrchestratorActivity(
            activeTurns: turnPhases.count,
            phase: turnPhases.values.max {
                OrchestratorActivity.rank($0) < OrchestratorActivity.rank($1)
            } ?? .idle,
            failureReason: lastFailureReason,
            activeTasks: taskSnapshots(activeOnly: true)
        )
    }

    /// Pushes the current aggregate to every subscriber. Actor-isolated.
    private func broadcast() {
        let snapshot = currentActivity()
        for continuation in activityObservers.values {
            continuation.yield(snapshot)
        }
    }

    /// Sets (or, with `nil`, clears) a turn's phase and broadcasts.
    private func setPhase(_ phase: OrchestratorPhase?, turn: Int) {
        turnPhases[turn] = phase
        if var record = taskRecords[turn] {
            record.phase = phase ?? .idle
            taskRecords[turn] = record
        }
        broadcast()
    }

    /// Ends a turn: drops its phase and task handle, keeping any sticky
    /// failure so UI can still show it.
    private func finishTurn(
        _ turn: Int,
        outcome: AIKitSessionUsageOutcome? = nil
    ) async {
        let summary = finishTask(turn, outcome: outcome)
        await persistUsage(summary)
        turnPhases[turn] = nil
        turnTasks[turn] = nil
        broadcast()
    }

    /// Records a sticky failure reason for a turn and ends it.
    private func recordFailure(
        _ reason: String,
        turn: Int,
        outcome: AIKitSessionUsageOutcome = .failed
    ) async {
        lastFailureReason = reason
        let summary = finishTask(turn, failureReason: reason, outcome: outcome)
        await persistUsage(summary)
        turnPhases[turn] = nil
        turnTasks[turn] = nil
        broadcast()
    }

    private func registerTask(_ task: Task<Void, Never>, turn: Int) {
        turnTasks[turn] = task
    }

    /// The built-in `reportFailure` escape hatch rides along with any view
    /// that exposes at least one tool; a tool-less context stays pure chat.
    private static func withBuiltinTools(_ names: Set<String>) -> Set<String> {
        names.isEmpty ? names : names.union([ReportFailureTool.toolName])
    }

    /// A concise, user-facing message for a terminal error.
    private func errorMessage(_ error: any Error) -> String {
        if let modelError = error as? LanguageModelError,
           case .guardrailViolation(let violation) = modelError {
            return violation.debugDescription
        }
        if let deadline = error as? TurnDeadlineExceeded {
            return "Stopped after exceeding the \(Int(deadline.budget))s budget."
        }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    @available(*, deprecated, message: "The Orchestrator pipeline is superseded by the official session driven directly: build a DynamicProfile (model, generation options, `.guardrails(_:)`, `.refusalEscapeHatch()`), run it with LanguageModelSession(profile:) — or AIKitConversation for retry/deadline/usage policies. See the AIKit README migration table.")
    public init(
        model: OrchestratorModel,
        tools: [any Tool],
        memory: any MemoryStore,
        contextResolver: ContextResolver,
        guardrails: PolicyEngine,
        usageRecorder: (any AIKitSessionUsageRecording)? = nil,
        options: Options = .init()
    ) {
        self.init(
            testing: model,
            tools: tools,
            memory: memory,
            contextResolver: contextResolver,
            guardrails: guardrails,
            usageRecorder: usageRecorder,
            options: options
        )
    }

    /// The non-deprecated seam the pinned legacy-behavior tests construct
    /// through while the public initializers carry deprecation warnings.
    internal init(
        testing model: OrchestratorModel,
        tools: [any Tool],
        memory: any MemoryStore,
        contextResolver: ContextResolver,
        guardrails: PolicyEngine,
        usageRecorder: (any AIKitSessionUsageRecording)? = nil,
        options: Options = .init()
    ) {
        self.model = model
        // AIKit's built-in tools (currently just `reportFailure`) ride along
        // by default, so hosts hand over nothing; a host tool under the same
        // name wins.
        var allTools = tools
        if !allTools.contains(where: { $0.name == ReportFailureTool.toolName }) {
            allTools.append(ReportFailureTool())
        }
        self.allTools = allTools
        self.tools = ToolSet(allTools)
        self.memory = memory
        self.contextResolver = contextResolver
        self.guardrails = guardrails
        self.usageRecorder = usageRecorder
        self.options = options
    }

    /// The default turn: the session's profile is synthesized from the resolved
    /// view context — AIKit's base preamble plus the context's system-prompt
    /// fragment, and the registered tools subset by the context's tool names.
    public func run(_ instruction: String) -> AsyncThrowingStream<OrchestratorEvent, any Error> {
        makeRunStream(
            instruction: instruction,
            render: { context in
                PromptRenderer.render(instruction: instruction, context: context)
            },
            makeSession: { [self] context, rendered, viewID, turnID, emit in
                // The view's tool subset is fixed for the turn. A tool-less
                // context stays pure chat.
                let activeTools = tools.subset(for: Self.withBuiltinTools(context.toolNames))
                return turnSession(
                    tools: activeTools,
                    instructions: rendered.instructions,
                    viewID: viewID,
                    turnID: turnID,
                    emit: emit
                )
            }
        )
    }

    /// The same turn machinery — view-context resolution, the guardrail stages,
    /// retry/deadline policy, usage records, and the event/activity streams —
    /// driving a host-authored `DynamicProfile` instead of the synthesized one.
    ///
    /// The profile fully owns the turn's instructions and tools; AIKit
    /// contributes only the runtime around them. The tool-stage guardrails and
    /// turn hooks still ride the profile through `TurnHooksModifier`, and the
    /// `prePrompt`/`finalResult` rails still bracket the call on the instruction
    /// and the final text. Pass a *bare* profile: the orchestrator owns the
    /// model (its `OrchestratorModel`) and the generation options (temperature,
    /// max tokens), so do not pre-apply `.model`/`.temperature` to it.
    public func run<Profile: LanguageModelSession.DynamicProfile & Sendable>(
        _ instruction: String,
        profile: Profile
    ) -> AsyncThrowingStream<OrchestratorEvent, any Error> {
        makeRunStream(
            instruction: instruction,
            render: { _ in
                // A host profile owns its own instructions; there is nothing to
                // render. The prompt still reaches the `prePrompt` rails and the
                // `promptBuilt` event as the user prompt.
                RenderedPrompt(instructions: "", userPrompt: instruction, toolNames: [])
            },
            makeSession: { [self] _, _, viewID, turnID, emit in
                hostTurnSession(
                    profile: profile,
                    viewID: viewID,
                    turnID: turnID,
                    emit: emit
                )
            }
        )
    }

    /// Shared turn setup for both `run` variants: assigns a turn id, clears any
    /// sticky failure, and drives the loop with the given prompt renderer and
    /// per-attempt session factory (the only two things the variants differ in).
    private func makeRunStream(
        instruction: String,
        render: @escaping @Sendable (ResolvedContext) -> RenderedPrompt,
        makeSession: @escaping @Sendable (
            ResolvedContext, RenderedPrompt, ViewContext.ID, Int,
            @escaping @Sendable (OrchestratorEvent) -> Void
        ) -> LanguageModelSession
    ) -> AsyncThrowingStream<OrchestratorEvent, any Error> {
        let turnID = nextTurnID()
        startTask(instruction, turn: turnID)
        // A new turn supersedes any prior failure.
        lastFailureReason = nil
        setPhase(.preparing, turn: turnID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.runTurn(
                    instruction,
                    turnID: turnID,
                    render: render,
                    makeSession: makeSession,
                    emit: { continuation.yield($0) }
                )
                continuation.finish()
            }
            registerTask(task, turn: turnID)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs one turn's loop and finishes it. Actor-isolated so the loop and
    /// `finishTurn` are same-actor (no extra hops) and the `Task` in `run`
    /// has a single clean `await`.
    private func runTurn(
        _ instruction: String,
        turnID: Int,
        render: @escaping @Sendable (ResolvedContext) -> RenderedPrompt,
        makeSession: @escaping @Sendable (
            ResolvedContext, RenderedPrompt, ViewContext.ID, Int,
            @escaping @Sendable (OrchestratorEvent) -> Void
        ) -> LanguageModelSession,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) async {
        await loop(
            instruction,
            turnID: turnID,
            render: render,
            makeSession: makeSession,
            emit: emit
        )
        await finishTurn(turnID)
    }

    public func snapshot(
        recentActivityLimit: Int = 10,
        recentTaskLimit: Int = 8
    ) async -> OrchestratorSnapshot {
        let contexts = await contextResolver.current()
        let resolved = await contextResolver.merged()
        let manifest = tools.descriptors(for: resolved.toolNames)
        let viewID = resolved.stack.isEmpty ? nil : resolved.leafID
        let recent = (try? await memory.recent(
            limit: recentActivityLimit,
            view: viewID
        )) ?? []
        return OrchestratorSnapshot(
            contexts: contexts,
            resolvedContext: resolved,
            availableTools: manifest,
            recentActivities: recent,
            recentTasks: taskSnapshots(matching: viewID, limit: recentTaskLimit)
        )
    }

    // MARK: - Loop

    private func loop(
        _ instruction: String,
        turnID: Int,
        render: @escaping @Sendable (ResolvedContext) -> RenderedPrompt,
        makeSession: @escaping @Sendable (
            ResolvedContext, RenderedPrompt, ViewContext.ID, Int,
            @escaping @Sendable (OrchestratorEvent) -> Void
        ) -> LanguageModelSession,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) async {
        let context = await contextResolver.merged()
        let viewID = context.leafID
        setTaskViewID(viewID, turn: turnID)
        await recordActivity(
            viewID: viewID, kind: .userInstruction, text: instruction, turn: turnID
        )

        if let budget = options.maxTurnDuration, !budget.isFinite {
            let error = AIKitConversationError.invalidDeadline
            await recordFailure(errorMessage(error), turn: turnID)
            emit(.error(error))
            return
        }
        let deadline = options.maxTurnDuration.map {
            ContinuousClock.now.advanced(by: .seconds($0))
        }

        // The prompt snapshot the `prePrompt` rails inspect and `promptBuilt`
        // reports. The session's profile (tools + instructions) is built per
        // attempt by `makeSession`, since a fresh session is created each retry.
        let rendered = render(context)
        emit(.promptBuilt(rendered))

        var attempt = 0
        while true {
            if Task.isCancelled {
                await finishTurn(turnID, outcome: .cancelled)
                return
            }
            if let deadline, ContinuousClock.now >= deadline {
                let error = TurnDeadlineExceeded(budget: options.maxTurnDuration ?? 0)
                await recordFailure(errorMessage(error), turn: turnID)
                emit(.error(error))
                return
            }
            // A fresh official session per attempt: the session owns the
            // in-turn transcript and executes the tools natively, with
            // AIKit's guardrails riding its profile hooks. Created outside
            // the `do` so the catch paths can still account the tokens a
            // failed or cancelled attempt consumed.
            let session = makeSession(context, rendered, viewID, turnID, emit)
            do {
                setPhase(.preparing, turn: turnID)
                let warnings = try await withTurnDeadline(deadline) {
                    try await self.guardrails.verify(.prePrompt, .prePrompt(rendered))
                }
                for warning in warnings {
                    emit(.verification(stage: .prePrompt, outcome: .warn(reason: warning.reason)))
                }

                setPhase(.thinking, turn: turnID)
                let result = try await withTurnDeadline(deadline) {
                    try await self.converse(session, instruction: instruction, emit: emit)
                }
                setPhase(.verifying, turn: turnID)
                _ = try await withTurnDeadline(deadline) {
                    try await self.guardrails.verify(
                        .finalResult, .finalResult(result.text)
                    )
                }
                // The attempt's usage is the session's lifetime usage: the
                // session is fresh per attempt and accumulates every model
                // call, where `Response.usage` carries only the final one.
                let usage = TokenUsage(session.usage)
                addUsage(usage, turn: turnID)
                emit(.usage(usage))
                if !result.reasoning.isEmpty {
                    emit(.reasoningDelta(result.reasoning))
                }

                emit(.verification(stage: .finalResult, outcome: .pass))
                await recordActivity(
                    viewID: viewID, kind: .llmResponse, text: result.text, turn: turnID
                )
                emit(.llmDelta(result.text))
                emit(.finalAnswer(result.text))
                return
            } catch is CancellationError {
                recordAttemptUsage(of: session, turn: turnID, emit: emit)
                await finishTurn(turnID, outcome: .cancelled)
                return
            } catch {
                recordAttemptUsage(of: session, turn: turnID, emit: emit)
                // An error thrown inside a tool's `call` reaches the host
                // wrapped in the official `ToolCallError`.
                let error = ErrorClassifier.underlyingError(error)
                if Task.isCancelled || error is CancellationError {
                    await finishTurn(turnID, outcome: .cancelled)
                    return
                }
                // The model bailed out via `reportFailure`: a refusal, not an
                // error — surface the reason and end the turn.
                if let refusal = error as? TurnRefusal {
                    await recordFailure(refusal.reason, turn: turnID, outcome: .refused)
                    emit(.failure(reason: refusal.reason))
                    return
                }
                attempt += 1
                await recordActivity(
                    viewID: viewID, kind: .error, text: "\(error)", turn: turnID
                )
                let decision = await errorHandler.handle(
                    error, attempt: attempt, policy: options.retry
                )
                switch decision {
                case .abort(let cause):
                    await recordFailure(errorMessage(cause), turn: turnID)
                    emit(.error(cause))
                    return
                case .retry(let delay):
                    do {
                        try await withTurnDeadline(deadline) {
                            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                        }
                    } catch {
                        if Task.isCancelled {
                            await finishTurn(turnID, outcome: .cancelled)
                        } else {
                            await recordFailure(errorMessage(error), turn: turnID)
                            emit(.error(error))
                        }
                        return
                    }
                    continue
                }
            }
        }
    }

    // MARK: - Session conversation

    private struct TurnResult: Sendable {
        var text: String
        var reasoning: String
    }

    /// Accounts the tokens an attempt consumed before it failed or was
    /// cancelled — the rounds already run (and reported by the executor)
    /// would otherwise vanish from the task record and the usage events.
    /// Skips all-zero usage so an attempt that never reached the model
    /// (e.g. a pre-prompt guardrail block) doesn't count a round trip.
    private func recordAttemptUsage(
        of session: LanguageModelSession,
        turn: Int,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) {
        let usage = TokenUsage(session.usage)
        guard usage != .zero else { return }
        addUsage(usage, turn: turn)
        emit(.usage(usage))
    }

    /// One official session call carrying the whole turn: the session runs
    /// the tool rounds internally and returns the final text. Streaming
    /// buffers native snapshots until the host final-result rail accepts them.
    private func converse(
        _ session: LanguageModelSession,
        instruction: String,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws -> TurnResult {
        let generationOptions = GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maxTokens
        )
        guard options.stream else {
            let response = try await session.respond(
                to: instruction, options: generationOptions
            )
            return TurnResult(
                text: response.content,
                reasoning: Self.reasoningText(in: response.transcriptEntries)
            )
        }

        let response = try await session.streamResponse(to: instruction, options: generationOptions).collect()
        try Task.checkCancellation()
        return TurnResult(text: response.content, reasoning: Self.reasoningText(in: response.transcriptEntries))
    }

    /// The turn's reasoning text, recovered from the official transcript
    /// entries (the session surface exposes reasoning only there).
    private static func reasoningText(
        in entries: ArraySlice<Transcript.Entry>
    ) -> String {
        entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            let text = reasoning.segments.compactMap { segment -> String? in
                guard case .text(let textSegment) = segment else { return nil }
                return textSegment.content
            }.joined()
            return text.isEmpty ? nil : text
        }.joined()
    }

    // MARK: - Turn session (tools run natively, guardrails ride the hooks)

    /// The official session for one attempt, built as a `DynamicProfile`:
    /// tools go to the session unwrapped, and AIKit's tool-stage guardrails
    /// run inside the session machinery through the official
    /// `onToolCall`/`onToolOutput` hooks (installed by `TurnHooksModifier`) —
    /// the way `SystemLanguageModel.Guardrails` screens the system model. A
    /// block throws the official `LanguageModelError.guardrailViolation`
    /// before the tool executes, aborting the session call.
    private nonisolated func turnSession(
        tools: [any Tool],
        instructions: String,
        viewID: ViewContext.ID,
        turnID: Int,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) -> LanguageModelSession {
        turnSession(
            model: model.model,
            tools: tools,
            instructions: instructions,
            viewID: viewID,
            turnID: turnID,
            emit: emit
        )
    }

    /// Generic over the model so the stored `any LanguageModel` is opened at
    /// this boundary: the profile chain below stays a concrete opaque type
    /// (an `any` opened mid-chain erases it to `any DynamicProfile`, which
    /// region analysis cannot prove disconnected for the `sending` profile
    /// parameter).
    private nonisolated func turnSession(
        model: some LanguageModel,
        tools: [any Tool],
        instructions: String,
        viewID: ViewContext.ID,
        turnID: Int,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) -> LanguageModelSession {
        LanguageModelSession(profile:
            LanguageModelSession.Profile {
                Instructions(instructions)
                tools
            }
            .model(model)
            .modifier(TurnHooksModifier(
                orchestrator: self,
                viewID: viewID,
                turnID: turnID,
                emit: emit
            ))
        )
    }

    /// The host-profile counterpart of `turnSession`: the caller's
    /// `DynamicProfile` supplies the instructions and tools, and the
    /// orchestrator layers on its configured model and the same tool-stage
    /// hooks the default path installs.
    private nonisolated func hostTurnSession<Profile: LanguageModelSession.DynamicProfile & Sendable>(
        profile: Profile,
        viewID: ViewContext.ID,
        turnID: Int,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) -> LanguageModelSession {
        hostTurnSession(
            model: model.model,
            profile: profile,
            viewID: viewID,
            turnID: turnID,
            emit: emit
        )
    }

    /// Generic over the model for the same reason as `turnSession`: opening the
    /// stored `any LanguageModel` here keeps the profile chain a concrete opaque
    /// type, which region analysis requires for the session's `sending` profile
    /// parameter (an `any` opened mid-chain erases it to `any DynamicProfile`).
    private nonisolated func hostTurnSession<Model: LanguageModel, Profile: LanguageModelSession.DynamicProfile & Sendable>(
        model: Model,
        profile: Profile,
        viewID: ViewContext.ID,
        turnID: Int,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) -> LanguageModelSession {
        LanguageModelSession(profile:
            profile
                .model(model)
                .modifier(TurnHooksModifier(
                    orchestrator: self,
                    viewID: viewID,
                    turnID: turnID,
                    emit: emit
                ))
        )
    }

    /// The `preToolUse` stage, run by the session before the tool executes.
    /// The `reportFailure` refusal is intercepted ahead of the rails so an
    /// allowlist that (correctly) omits it cannot block the bail-out.
    fileprivate func willExecuteTool(
        _ call: Transcript.ToolCall,
        viewID: ViewContext.ID,
        turnID: Int,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws {
        if call.toolName == ReportFailureTool.toolName {
            throw TurnRefusal(reason: ReportFailureTool.reason(from: call.arguments))
        }

        let warnings = try await guardrails.verify(.preToolUse, .preToolUse(call))
        for warning in warnings {
            emit(.verification(stage: .preToolUse, outcome: .warn(reason: warning.reason)))
        }
        emit(.verification(stage: .preToolUse, outcome: .pass))

        setPhase(.callingTool(call.toolName), turn: turnID)
        emit(.toolCall(call))
        await recordActivity(
            viewID: viewID,
            kind: .toolInvoked,
            text: "\(call.toolName) \(call.arguments.jsonString)",
            turn: turnID
        )
    }

    /// The `postToolUse` stage, run by the session on the executed call's
    /// official output entry. A thrown tool error never reaches here — it
    /// aborts the session call as the official `ToolCallError` and surfaces
    /// at the turn loop's catch site.
    fileprivate func didExecuteTool(
        _ call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        viewID: ViewContext.ID,
        turnID: Int,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws {
        defer { setPhase(.thinking, turn: turnID) }
        let warnings = try await guardrails.verify(.postToolUse, .postToolUse(call, output))
        for warning in warnings {
            emit(.verification(stage: .postToolUse, outcome: .warn(reason: warning.reason)))
        }
        emit(.verification(stage: .postToolUse, outcome: .pass))

        emit(.toolResult(call, output))
        await recordActivity(
            viewID: viewID,
            kind: .toolResult,
            text: "\(call.toolName) -> \(output.contentText)",
            turn: turnID
        )
    }

    // MARK: - Deadline

    /// Races `operation` against the turn deadline. Returning the operation's
    /// value cancels the timer; the timer firing first throws
    /// `TurnDeadlineExceeded` and cancels the in-flight session call so a
    /// slow request is cancelled; settlement still requires cooperative cleanup.
    private func withTurnDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let deadline else { return try await operation() }
        let budget = options.maxTurnDuration ?? 0
        if ContinuousClock.now >= deadline {
            throw TurnDeadlineExceeded(budget: budget)
        }
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


/// Installs the orchestrator's tool-stage hooks on a turn's profile:
/// `preToolUse`/`postToolUse` guardrails, the `reportFailure` refusal
/// interception, host events, phases, and the durable activity log. A
/// `DynamicProfileModifier` (like `GuardrailsModifier`) so the profile that
/// crosses into the session holds only this Sendable value — the hook
/// closures are formed by the session machinery itself when it resolves the
/// profile.
private struct TurnHooksModifier: LanguageModelSession.DynamicProfileModifier {
    let orchestrator: Orchestrator
    let viewID: ViewContext.ID
    let turnID: Int
    let emit: @Sendable (OrchestratorEvent) -> Void

    func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content
            .onResponse { [orchestrator, turnID] _ in
                await orchestrator.recordModelRound(turn: turnID)
            }
            .onToolCall { [orchestrator, viewID, turnID, emit] call in
                try await orchestrator.willExecuteTool(
                    call, viewID: viewID, turnID: turnID, emit: emit
                )
            }
            .onToolOutput { [orchestrator, viewID, turnID, emit] call, output in
                try await orchestrator.didExecuteTool(
                    call, output: output, viewID: viewID, turnID: turnID, emit: emit
                )
            }
    }
}
