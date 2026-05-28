import Foundation
import OSLog
import AIKitCore
import AIKitCapability
import AIKitSafety

/// Events streamed to the host for one turn.
public enum OrchestratorEvent: Sendable {
    case promptBuilt(RenderedPrompt)
    case llmDelta(String)
    /// A chunk of model reasoning / chain-of-thought. Streaming emits these
    /// incrementally; non-streaming emits one with the whole reasoning text.
    /// Empty when the model or provider produced no reasoning.
    case reasoningDelta(String)
    case toolCall(name: String, input: Data)
    case toolResult(name: String, output: Data)
    case verification(stage: Verifier.Stage, outcome: Verifier.Outcome)
    /// Token usage for one LLM call. Emitted once per iteration so hosts can
    /// do cost/telemetry accounting even on the streaming path.
    case usage(TokenUsage)
    case finalAnswer(String)
    /// The turn ended without completing the request — either the model
    /// called `reportFailure` (a vague / unexecutable ask) or a terminal
    /// error was mapped to a user-facing reason.
    case failure(reason: String)
    case error(any Error)
}

private extension String {
    var emptyAsNil: String? {
        isEmpty ? nil : self
    }
}

/// A UI-friendly snapshot of the runtime state the orchestrator already owns.
public struct OrchestratorSnapshot: Sendable, Hashable {
    public var contexts: [ViewContext]
    public var resolvedContext: ResolvedContext
    public var availableTools: [ToolDescriptor]
    public var recentActivities: [UsageEvent]

    public init(
        contexts: [ViewContext],
        resolvedContext: ResolvedContext,
        availableTools: [ToolDescriptor],
        recentActivities: [UsageEvent]
    ) {
        self.contexts = contexts
        self.resolvedContext = resolvedContext
        self.availableTools = availableTools
        self.recentActivities = recentActivities
    }
}

/// What the orchestrator is doing right now, for a single turn. Aggregated
/// across all in-flight turns by `OrchestratorActivity`.
public enum OrchestratorPhase: Sendable, Equatable {
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
            }
        }
        if let failureReason { return failureReason }
        return "Idle"
    }

    public static let idle = OrchestratorActivity(
        activeTurns: 0, phase: .idle, failureReason: nil
    )

    /// Higher rank wins when aggregating concurrent turns into one `phase`.
    static func rank(_ phase: OrchestratorPhase) -> Int {
        switch phase {
        case .idle: 0
        case .preparing: 1
        case .verifying: 2
        case .thinking: 3
        case .callingTool: 4
        }
    }
}

/// The single entry point a host app calls once per user instruction. An actor
/// so concurrent `run` calls on one instance serialize cleanly.
public actor Orchestrator {
    public struct Options: Sendable {
        /// The model to request. `nil` defers to the provider configuration's
        /// selected model. If neither has a model, the turn fails before
        /// building a request.
        public var model: String?
        public var maxIterations: Int
        public var stream: Bool
        public var retry: RetryPolicy
        /// An overall wall-clock budget for the whole turn (all iterations and
        /// retries combined). `nil` (default) is unbounded. Bounds the case
        /// where a too-low `configuration.timeout` against a slow local model
        /// is classified transient and retried `maxAttempts` times, costing
        /// ≈ N × timeout before aborting; with a budget set the turn aborts
        /// with `TurnDeadlineExceeded` instead of stacking slow failures.
        ///
        /// The budget races every blocking await in the turn — LLM calls,
        /// guardrail passes, and tool invocations — so a hung tool or a slow
        /// rail can't overrun it; it is a hard wall-clock cap, not just a
        /// per-iteration-boundary check.
        public var maxTurnDuration: TimeInterval?
        public var memoryWindow: Int
        public var temperature: Double?
        public var maxTokens: Int?
        /// Provider-specific request knobs (`num_ctx`, `keep_alive`, `stop`,
        /// `top_p`, `seed`, …) forwarded on every LLM call this turn.
        public var extraBody: [String: JSONValue]
        /// Controls the fenced-```tool``` fallback (prompt instruction +
        /// recovery parsing). `nil` (the default) auto-resolves per turn:
        /// enabled only when the provider does not support native function
        /// calling, so native-capable backends don't waste context or get
        /// prompted to emit a redundant fenced block. Set `true`/`false` to
        /// force it (e.g. a tool-less model behind a native-looking provider).
        public var toolCallFallback: Bool?
        /// Adds AIKit's WorkflowSpec schema to prompts and native tool
        /// manifests. This lets the model describe multiple dependent tool
        /// calls in one response; the device executes them locally and emits
        /// the final answer without a second LLM pass.
        public var workflowPlanning: Bool

        public init(
            model: String? = nil,
            maxIterations: Int = 8,
            stream: Bool = true,
            retry: RetryPolicy = .default,
            maxTurnDuration: TimeInterval? = nil,
            memoryWindow: Int = 20,
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            extraBody: [String: JSONValue] = [:],
            toolCallFallback: Bool? = nil,
            workflowPlanning: Bool = true
        ) {
            self.model = model
            self.maxIterations = maxIterations
            self.stream = stream
            self.retry = retry
            self.maxTurnDuration = maxTurnDuration
            self.memoryWindow = memoryWindow
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.extraBody = extraBody
            self.toolCallFallback = toolCallFallback
            self.workflowPlanning = workflowPlanning
        }
    }

    private let llm: LLMClient
    private let tools: ToolRegistry
    private let memory: any MemoryStore
    private let contextResolver: ContextResolver
    private let guardrails: PolicyEngine
    private let errorHandler = ErrorHandler()
    private let options: Options
    private let logger = AIKitLog.runtime

    private var turnCounter = 0
    /// Latest phase per in-flight turn id. Actor-isolated, so concurrent
    /// turns mutate it safely without any extra synchronization.
    private var turnPhases: [Int: OrchestratorPhase] = [:]
    /// The in-flight `loop` task per turn id, so a turn can be cancelled.
    private var turnTasks: [Int: Task<Void, Never>] = [:]
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

    /// Cancels every in-flight turn and clears any sticky failure, returning
    /// the orchestrator to idle. Safe to call from UI (e.g. a Cancel button).
    public func cancelActiveTurns() {
        for task in turnTasks.values { task.cancel() }
        turnTasks.removeAll()
        turnPhases.removeAll()
        lastFailureReason = nil
        broadcast()
    }

    /// A live stream of this orchestrator's activity: the current state is
    /// emitted immediately on subscription, then again on every phase or
    /// turn-count change. Each subscriber gets an independent stream, so a
    /// floating assistant button reflects turns started anywhere — including
    /// overlapping ones — not just its own session's.
    public nonisolated func activityUpdates() -> AsyncStream<OrchestratorActivity> {
        AsyncStream { continuation in
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
            failureReason: lastFailureReason
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
        broadcast()
    }

    /// Ends a turn: drops its phase and task handle, keeping any sticky
    /// failure so UI can still show it.
    private func finishTurn(_ turn: Int) {
        turnPhases[turn] = nil
        turnTasks[turn] = nil
        broadcast()
    }

    /// Records a sticky failure reason for a turn and ends it.
    private func recordFailure(_ reason: String, turn: Int) {
        lastFailureReason = reason
        turnPhases[turn] = nil
        turnTasks[turn] = nil
        broadcast()
    }

    private func registerTask(_ task: Task<Void, Never>, turn: Int) {
        turnTasks[turn] = task
    }

    /// The `reportFailure` reason among `calls`, if the model invoked it.
    private func failureReason(in calls: [ToolCall]) -> String? {
        for call in calls where call.name == ReportFailureTool.name {
            if case let .object(fields) = call.input,
               case let .string(reason)? = fields["reason"],
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return reason
            }
            return "The assistant could not confidently complete this request."
        }
        return nil
    }

    /// A concise, user-facing message for a terminal error.
    private func errorMessage(_ error: any Error) -> String {
        if let violation = error as? GuardrailViolation {
            return "Blocked by \(violation.railID): \(violation.reason)"
        }
        if let iteration = error as? IterationLimitExceeded {
            return "Stopped after reaching the \(iteration.limit)-step limit."
        }
        if let deadline = error as? TurnDeadlineExceeded {
            return "Stopped after exceeding the \(Int(deadline.budget))s budget."
        }
        if let llmError = error as? LLMError {
            return llmError.errorDescription ?? "\(llmError)"
        }
        return "\(error)"
    }

    public init(
        llm: LLMClient,
        tools: ToolRegistry,
        memory: any MemoryStore,
        contextResolver: ContextResolver,
        guardrails: PolicyEngine,
        options: Options = .init()
    ) {
        self.llm = llm
        self.tools = tools
        self.memory = memory
        self.contextResolver = contextResolver
        self.guardrails = guardrails
        self.options = options
    }

    public func run(_ instruction: String) -> AsyncThrowingStream<OrchestratorEvent, any Error> {
        let turnID = nextTurnID()
        // A new turn supersedes any prior failure.
        lastFailureReason = nil
        setPhase(.preparing, turn: turnID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.runTurn(instruction, turnID: turnID, emit: { continuation.yield($0) })
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
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) async {
        await loop(instruction, turnID: turnID, emit: emit)
        finishTurn(turnID)
    }

    public func snapshot(recentActivityLimit: Int = 10) async -> OrchestratorSnapshot {
        let contexts = await contextResolver.current()
        let resolved = await contextResolver.merged()
        let manifest = await tools.manifest(for: resolved.toolNames)
        let viewID = resolved.stack.isEmpty ? nil : resolved.leafID
        let recent = (try? await memory.recent(
            limit: recentActivityLimit,
            view: viewID
        )) ?? []
        return OrchestratorSnapshot(
            contexts: contexts,
            resolvedContext: resolved,
            availableTools: manifest,
            recentActivities: recent
        )
    }

    // MARK: - Loop

    private func loop(
        _ instruction: String,
        turnID: Int,
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) async {
        let context = await contextResolver.merged()
        let viewID = context.leafID
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .userInstruction, text: instruction
        ))

        // Resolve the fenced-tool fallback once per turn: an explicit option
        // wins; otherwise enable it only for providers without native tools.
        let useFallback = options.toolCallFallback ?? !llm.supportsNativeTools
        let configuredModel = (options.model ?? llm.defaultModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .emptyAsNil

        let deadline = options.maxTurnDuration.map {
            ContinuousClock.now.advanced(by: .seconds($0))
        }

        var transcript: [TranscriptEntry] = []
        var pendingCorrection: String?
        var attempt = 0

        for _ in 0..<options.maxIterations {
            if Task.isCancelled { return }
            if let deadline, ContinuousClock.now >= deadline {
                let error = TurnDeadlineExceeded(budget: options.maxTurnDuration ?? 0)
                recordFailure(errorMessage(error), turn: turnID)
                emit(.error(error))
                return
            }
            do {
                setPhase(.preparing, turn: turnID)
                if let correction = pendingCorrection {
                    transcript.append(.correctiveGuidance(correction))
                    pendingCorrection = nil
                }

                let recent = (try? await memory.recent(
                    limit: options.memoryWindow, view: viewID
                )) ?? []
                let manifest = await tools.manifest(for: context.toolNames)
                guard let selectedModel = configuredModel else {
                    let error = LLMError.missingModel
                    recordFailure(errorMessage(error), turn: turnID)
                    emit(.error(error))
                    return
                }

                let request = PromptBuilder.build(
                    instruction: instruction,
                    context: context,
                    memory: recent,
                    transcript: transcript,
                    toolManifest: manifest,
                    model: selectedModel,
                    temperature: options.temperature,
                    maxTokens: options.maxTokens,
                    extraBody: options.extraBody,
                    toolCallFallbackHint: useFallback,
                    workflowPlanningHint: options.workflowPlanning
                )
                let rendered = RenderedPrompt(request: request, toolNames: context.toolNames)
                emit(.promptBuilt(rendered))

                let warnings = try await withTurnDeadline(deadline) {
                    try await self.guardrails.verify(.prePrompt, .prePrompt(rendered))
                }
                for warning in warnings {
                    emit(.verification(stage: .prePrompt, outcome: .warn(reason: warning)))
                }

                setPhase(.thinking, turn: turnID)
                let response = try await withTurnDeadline(deadline) {
                    try await self.callLLM(request, emit: emit)
                }
                emit(.usage(response.usage))
                // Streaming already emitted reasoning incrementally inside
                // `callLLM`; for one-shot calls surface it once here.
                if !options.stream {
                    let reasoning = response.reasoning
                    if !reasoning.isEmpty { emit(.reasoningDelta(reasoning)) }
                }
                let parsed = try OutputParser.parse(
                    response, allowToolCallFallback: useFallback
                )

                switch parsed {
                case .final(let text):
                    // A model coached only by the generic fallback instruction
                    // sometimes fences a tool call as ```json instead of
                    // ```tool. It can't be recovered (that would derail real
                    // answers), but flag it so it isn't delivered silently.
                    if useFallback, OutputParser.nearMissFencedToolBlock(in: text) {
                        emit(.verification(stage: .finalResult, outcome: .warn(
                            reason: "Response contains a fenced JSON block that "
                                + "looks like a tool call but is not tagged "
                                + "`tool`; delivered as the final answer instead "
                                + "of being executed."
                        )))
                    }
                    setPhase(.verifying, turn: turnID)
                    _ = try await withTurnDeadline(deadline) {
                        try await self.guardrails.verify(
                            .finalResult, .finalResult(text)
                        )
                    }
                    emit(.verification(stage: .finalResult, outcome: .pass))
                    try? await memory.append(UsageEvent(
                        viewID: viewID, kind: .llmResponse, text: text
                    ))
                    emit(.finalAnswer(text))
                    return

                case .toolCalls(let calls):
                    if options.workflowPlanning {
                        throw OutputParser.ParserError.malformedWorkflow(
                            raw: "Expected a single \(WorkflowSpec.toolName) call or WorkflowSpec JSON, not direct tool calls."
                        )
                    }
                    if let reason = failureReason(in: calls) {
                        recordFailure(reason, turn: turnID)
                        emit(.failure(reason: reason))
                        return
                    }
                    let (entry, resolved) = Self.assistantTurn(text: nil, calls: calls)
                    transcript.append(entry)
                    try await executeBatch(
                        resolved, viewID: viewID, turnID: turnID, deadline: deadline,
                        transcript: &transcript, emit: emit
                    )

                case .mixed(let text, let calls):
                    if options.workflowPlanning {
                        throw OutputParser.ParserError.malformedWorkflow(
                            raw: "Expected a single \(WorkflowSpec.toolName) call or WorkflowSpec JSON, not direct tool calls."
                        )
                    }
                    if let reason = failureReason(in: calls) {
                        recordFailure(reason, turn: turnID)
                        emit(.failure(reason: reason))
                        return
                    }
                    // Non-stream mode never emitted deltas, so surface the
                    // narration that accompanies the tool call instead of
                    // dropping it. (Streaming already emitted it as deltas.)
                    if !options.stream, !text.isEmpty {
                        emit(.llmDelta(text))
                    }
                    let (entry, resolved) = Self.assistantTurn(text: text, calls: calls)
                    transcript.append(entry)
                    try await executeBatch(
                        resolved, viewID: viewID, turnID: turnID, deadline: deadline,
                        transcript: &transcript, emit: emit
                    )

                case .workflow(let plan):
                    try await executeWorkflow(
                        plan, narration: nil, manifest: manifest,
                        viewID: viewID, turnID: turnID, deadline: deadline,
                        transcript: &transcript, emit: emit
                    )
                    return

                case .mixedWorkflow(let text, let plan):
                    try await executeWorkflow(
                        plan, narration: text, manifest: manifest,
                        viewID: viewID, turnID: turnID, deadline: deadline,
                        transcript: &transcript, emit: emit
                    )
                    return
                }
                attempt = 0
            } catch {
                attempt += 1
                let decision = await errorHandler.handle(
                    error, attempt: attempt, policy: options.retry
                )
                try? await memory.append(UsageEvent(
                    viewID: viewID, kind: .error, text: "\(error)"
                ))
                switch decision {
                case .abort(let cause):
                    recordFailure(errorMessage(cause), turn: turnID)
                    emit(.error(cause))
                    return
                case .retry:
                    continue
                case .fallback(let prompt):
                    pendingCorrection = prompt
                    continue
                }
            }
        }
        let limitError = IterationLimitExceeded(limit: options.maxIterations)
        recordFailure(errorMessage(limitError), turn: turnID)
        emit(.error(limitError))
    }

    /// Rebuilds the assistant transcript entry from the parsed output rather
    /// than the raw `LLMResponse.content`. This is what makes the fenced-tool
    /// fallback correct: the model's content there is plain text holding the
    /// JSON, with no `tool_use` block, so trusting it would emit a `tool`
    /// message with no preceding `tool_calls` (rejected by OpenAI-compatible
    /// backends, mishandled by Ollama). Reconstructing also normalizes the
    /// native path: any call missing a usable id gets a stable synthetic one
    /// so the following `tool_result` references a real `tool_use` id.
    private static func assistantTurn(
        text: String?,
        calls: [ToolCall]
    ) -> (entry: TranscriptEntry, calls: [ToolCall]) {
        var blocks: [ContentBlock] = []
        if let text, !text.isEmpty { blocks.append(.text(text)) }
        var resolved: [ToolCall] = []
        resolved.reserveCapacity(calls.count)
        for call in calls {
            let id = (call.id?.isEmpty == false)
                ? call.id!
                : "fallback-\(UUID().uuidString)"
            var c = call
            c.id = id
            resolved.append(c)
            blocks.append(.toolUse(id: id, name: c.name, input: c.input))
        }
        return (.assistant(blocks), resolved)
    }

    private static func toolErrorOutput(_ error: any Error) -> Data {
        let payload = ["error": String(describing: error)]
        return (try? JSONEncoder().encode(payload))
            ?? Data(String(describing: error).utf8)
    }

    private static let skippedToolOutput = Data(
        #"{"error":"Skipped because an earlier tool call in this assistant batch failed."}"#.utf8
    )

    // MARK: - Tool execution

    private func executeBatch(
        _ calls: [ToolCall],
        viewID: ViewContext.ID,
        turnID: Int,
        deadline: ContinuousClock.Instant?,
        transcript: inout [TranscriptEntry],
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) async throws {
        for index in calls.indices {
            do {
                _ = try await execute(
                    calls[index],
                    viewID: viewID,
                    turnID: turnID,
                    deadline: deadline,
                    transcript: &transcript,
                    emit: emit
                )
            } catch {
                appendSkippedToolResults(
                    for: calls[(index + 1)...],
                    transcript: &transcript
                )
                throw error
            }
        }
    }

    private func executeWorkflow(
        _ spec: WorkflowSpec,
        narration: String?,
        manifest: [ToolDescriptor],
        viewID: ViewContext.ID,
        turnID: Int,
        deadline: ContinuousClock.Instant?,
        transcript: inout [TranscriptEntry],
        emit: @escaping @Sendable (OrchestratorEvent) -> Void
    ) async throws {
        if !options.stream, let narration, !narration.isEmpty {
            emit(.llmDelta(narration))
        }

        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(descriptors: manifest)
        )
        let guardrails = self.guardrails
        let tools = self.tools
        let memory = self.memory
        let logger = self.logger
        let descriptorsByName = Dictionary(uniqueKeysWithValues: manifest.map { ($0.name, $0) })
        let toolContext = ToolContext(
            viewID: viewID.rawValue,
            metadata: ["leafViewID": viewID.rawValue],
            logger: logger
        )
        let executor = WorkflowExecutor { node, resolvedInput, executionContext in
            guard let tool = node.tool else {
                throw WorkflowError.missingTool(nodeID: node.id)
            }
            let call = ToolCall(
                id: "workflow-\(node.id)",
                name: tool,
                input: resolvedInput
            )
            let (resolvedPayload, warnings) = try await guardrails.resolve(
                .preToolUse, .preToolUse(call)
            )
            for warning in warnings {
                emit(.verification(stage: .preToolUse, outcome: .warn(reason: warning)))
            }
            let effectiveCall: ToolCall
            if case .preToolUse(let rewritten) = resolvedPayload {
                effectiveCall = rewritten
            } else {
                effectiveCall = call
            }
            emit(.verification(stage: .preToolUse, outcome: .pass))

            let inputData = (try? effectiveCall.input.data()) ?? Data("{}".utf8)
            emit(.toolCall(name: effectiveCall.name, input: inputData))
            try? await memory.append(UsageEvent(
                viewID: viewID, kind: .toolInvoked,
                text: "\(effectiveCall.name) \(String(decoding: inputData, as: UTF8.self))"
            ))

            let outputValue: JSONValue
            do {
                outputValue = try await tools.call(
                    effectiveCall,
                    context: executionContext.toolContext
                )
            } catch {
                let output = Self.toolErrorOutput(error)
                _ = try await guardrails.verify(
                    .postToolUse,
                    .postToolUse(
                        name: effectiveCall.name,
                        output: output,
                        isError: true
                    )
                )
                emit(.verification(stage: .postToolUse, outcome: .pass))
                emit(.toolResult(name: effectiveCall.name, output: output))
                throw error
            }

            let diagnosticValue = WorkflowOutputRedactor.diagnosticValue(
                outputValue,
                node: node,
                descriptor: descriptorsByName[effectiveCall.name]
            )
            let diagnosticOutput = (try? diagnosticValue.data())
                ?? Data(WorkflowFinalRenderer.displayString(diagnosticValue).utf8)
            _ = try await guardrails.verify(
                .postToolUse,
                .postToolUse(name: effectiveCall.name, output: diagnosticOutput, isError: false)
            )
            emit(.verification(stage: .postToolUse, outcome: .pass))
            emit(.toolResult(name: effectiveCall.name, output: diagnosticOutput))
            try? await memory.append(UsageEvent(
                viewID: viewID, kind: .toolResult,
                text: "\(effectiveCall.name) -> \(String(decoding: diagnosticOutput, as: UTF8.self))"
            ))
            return outputValue
        }

        let result = try await withTurnDeadline(deadline) {
            try await executor.execute(
                validated,
                context: WorkflowExecutionContext(toolContext: toolContext)
            )
        }

        let final = (result.finalText ?? WorkflowFinalRenderer.displayString(result.finalValue))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .emptyAsNil
            ?? "Done."
        setPhase(.verifying, turn: turnID)
        _ = try await withTurnDeadline(deadline) {
            try await self.guardrails.verify(
                .finalResult, .finalResult(final)
            )
        }
        emit(.verification(stage: .finalResult, outcome: .pass))
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .llmResponse, text: final
        ))
        emit(.finalAnswer(final))
    }

    private func appendSkippedToolResults(
        for calls: ArraySlice<ToolCall>,
        transcript: inout [TranscriptEntry]
    ) {
        let content = String(decoding: Self.skippedToolOutput, as: UTF8.self)
        for call in calls {
            transcript.append(.toolResult(
                id: call.id ?? call.name,
                name: call.name,
                content: content,
                isError: true
            ))
        }
    }

    private func execute(
        _ call: ToolCall,
        viewID: ViewContext.ID,
        turnID: Int,
        deadline: ContinuousClock.Instant?,
        transcript: inout [TranscriptEntry],
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws -> Data {
        // `resolve` runs payload-rewriting rails (e.g. PIIRedactor in redact
        // mode) before the block checks, so the tool sees the sanitized input.
        // Raced against the turn budget so a slow rail can't overrun it.
        let (resolvedPayload, warnings) = try await withTurnDeadline(deadline) {
            try await self.guardrails.resolve(.preToolUse, .preToolUse(call))
        }
        for warning in warnings {
            emit(.verification(stage: .preToolUse, outcome: .warn(reason: warning)))
        }
        let effectiveCall: ToolCall
        if case .preToolUse(let rewritten) = resolvedPayload {
            effectiveCall = rewritten
        } else {
            effectiveCall = call
        }
        emit(.verification(stage: .preToolUse, outcome: .pass))

        let inputData = (try? effectiveCall.input.data()) ?? Data("{}".utf8)
        setPhase(.callingTool(effectiveCall.name), turn: turnID)
        emit(.toolCall(name: effectiveCall.name, input: inputData))
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .toolInvoked,
            text: "\(effectiveCall.name) \(String(decoding: inputData, as: UTF8.self))"
        ))

        let context = ToolContext(
            viewID: viewID.rawValue,
            metadata: ["leafViewID": viewID.rawValue],
            logger: logger
        )
        let output: Data
        do {
            // A hung or slow tool must not be able to overrun the turn budget,
            // so the invocation is raced against the deadline too.
            output = try await withTurnDeadline(deadline) {
                try await self.tools.call(
                    name: effectiveCall.name, jsonInput: inputData, context: context
                )
            }
        } catch {
            let isError = true
            let output = Self.toolErrorOutput(error)
            _ = try await withTurnDeadline(deadline) {
                try await self.guardrails.verify(
                    .postToolUse,
                    .postToolUse(
                        name: effectiveCall.name,
                        output: output,
                        isError: isError
                    )
                )
            }
            emit(.verification(stage: .postToolUse, outcome: .pass))
            emit(.toolResult(name: effectiveCall.name, output: output))
            let outputText = String(decoding: output, as: UTF8.self)
            try? await memory.append(UsageEvent(
                viewID: viewID, kind: .toolResult,
                text: "\(effectiveCall.name) -> \(outputText)"
            ))
            transcript.append(.toolResult(
                id: effectiveCall.id ?? effectiveCall.name,
                name: effectiveCall.name,
                content: outputText,
                isError: isError
            ))
            // Surface to the catch-site classifier (tool-retriable, fatal, …).
            throw error
        }

        let isError = false
        _ = try await withTurnDeadline(deadline) {
            try await self.guardrails.verify(
                .postToolUse,
                .postToolUse(name: effectiveCall.name, output: output, isError: isError)
            )
        }
        emit(.verification(stage: .postToolUse, outcome: .pass))
        emit(.toolResult(name: effectiveCall.name, output: output))
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .toolResult,
            text: "\(effectiveCall.name) -> \(String(decoding: output, as: UTF8.self))"
        ))

        transcript.append(.toolResult(
            id: effectiveCall.id ?? effectiveCall.name,
            name: effectiveCall.name,
            content: String(decoding: output, as: UTF8.self),
            isError: isError
        ))
        return output
    }

    // MARK: - Deadline

    /// Races `operation` against the turn deadline. Returning the operation's
    /// value cancels the timer; the timer firing first throws
    /// `TurnDeadlineExceeded` and cancels the in-flight LLM call so a single
    /// slow request can't outlive the whole turn budget.
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

    // MARK: - LLM

    private static let malformedToolInputRawKey = "__aikit_malformed_tool_input_raw"

    private static func malformedToolInput(raw: String) -> JSONValue {
        .object([malformedToolInputRawKey: .string(raw)])
    }

    private func callLLM(
        _ request: LLMRequest,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws -> LLMResponse {
        guard options.stream else {
            return try await llm.complete(request)
        }
        var text = ""
        var reasoning = ""
        var audioBlocks: [AudioContent] = []
        var toolBlocks: [(id: String, name: String, json: String)] = []
        var stopReason: StopReason = .endTurn
        var usage = TokenUsage.zero

        for try await chunk in llm.stream(request) {
            // Make deadline/host cancellation prompt: without this the loop
            // would keep draining the provider stream after the turn budget
            // fired or the caller cancelled.
            try Task.checkCancellation()
            switch chunk {
            case .textDelta(let delta):
                text += delta
                emit(.llmDelta(delta))
            case .reasoningDelta(let delta):
                reasoning += delta
                emit(.reasoningDelta(delta))
            case .audio(let audio):
                audioBlocks.append(audio)
                if let transcript = audio.transcript {
                    emit(.llmDelta(transcript))
                }
            case .toolUseStart(let id, let name):
                toolBlocks.append((id, name, ""))
            case .toolUseInputDelta(let id, let json):
                if let index = toolBlocks.firstIndex(where: { $0.id == id }) {
                    toolBlocks[index].json += json
                } else if !toolBlocks.isEmpty {
                    toolBlocks[toolBlocks.count - 1].json += json
                }
            case .toolUseStop:
                continue
            case .stop(let reason):
                stopReason = reason
            case .usage(let value):
                // Providers report usage across several events (Anthropic
                // splits input/output). Keep the largest seen of each field
                // so a later partial event can't zero out an earlier count.
                usage = TokenUsage(
                    inputTokens: max(usage.inputTokens, value.inputTokens),
                    outputTokens: max(usage.outputTokens, value.outputTokens)
                )
            }
        }

        var blocks: [ContentBlock] = []
        if !reasoning.isEmpty { blocks.append(.reasoning(reasoning)) }
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: audioBlocks.map(ContentBlock.audio))
        for tool in toolBlocks {
            let input: JSONValue
            if tool.json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                input = .object([:])
            } else if let data = tool.json.data(using: .utf8),
                      let value = try? JSONValue(data: data) {
                input = value
            } else {
                input = Self.malformedToolInput(raw: tool.json)
            }
            blocks.append(.toolUse(id: tool.id, name: tool.name, input: input))
        }
        return LLMResponse(content: blocks, stopReason: stopReason, usage: usage)
    }
}
