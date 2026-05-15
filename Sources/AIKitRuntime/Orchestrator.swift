import Foundation
import OSLog
import AIKitCore
import AIKitCapability
import AIKitSafety

/// Events streamed to the host for one turn.
public enum OrchestratorEvent: Sendable {
    case promptBuilt(RenderedPrompt)
    case llmDelta(String)
    case toolCall(name: String, input: Data)
    case toolResult(name: String, output: Data)
    case verification(stage: Verifier.Stage, outcome: Verifier.Outcome)
    case finalAnswer(String)
    case error(any Error)
}

/// The single entry point a host app calls once per user instruction. An actor
/// so concurrent `run` calls on one instance serialize cleanly.
public actor Orchestrator {
    public struct Options: Sendable {
        public var model: String
        public var maxIterations: Int
        public var stream: Bool
        public var retry: RetryPolicy
        public var memoryWindow: Int
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            model: String = AnthropicProvider.defaultModel,
            maxIterations: Int = 8,
            stream: Bool = true,
            retry: RetryPolicy = .default,
            memoryWindow: Int = 20,
            temperature: Double? = nil,
            maxTokens: Int? = nil
        ) {
            self.model = model
            self.maxIterations = maxIterations
            self.stream = stream
            self.retry = retry
            self.memoryWindow = memoryWindow
            self.temperature = temperature
            self.maxTokens = maxTokens
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
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.loop(instruction, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Loop

    private func loop(
        _ instruction: String,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async {
        let context = await contextResolver.merged()
        let viewID = context.leafID
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .userInstruction, text: instruction
        ))

        var transcript: [TranscriptEntry] = []
        var pendingCorrection: String?
        var attempt = 0

        for iteration in 0..<options.maxIterations {
            if Task.isCancelled { return }
            do {
                if let correction = pendingCorrection {
                    transcript.append(.toolResult(
                        id: "correction-\(iteration)",
                        name: "system",
                        content: correction,
                        isError: true
                    ))
                    pendingCorrection = nil
                }

                let recent = (try? await memory.recent(
                    limit: options.memoryWindow, view: viewID
                )) ?? []
                let manifest = await tools.manifest(for: context.toolNames)
                let request = PromptBuilder.build(
                    instruction: instruction,
                    context: context,
                    memory: recent,
                    transcript: transcript,
                    toolManifest: manifest,
                    model: options.model,
                    temperature: options.temperature,
                    maxTokens: options.maxTokens
                )
                let rendered = RenderedPrompt(request: request, toolNames: context.toolNames)
                emit(.promptBuilt(rendered))

                let warnings = try await guardrails.verify(.prePrompt, .prePrompt(rendered))
                for warning in warnings {
                    emit(.verification(stage: .prePrompt, outcome: .warn(reason: warning)))
                }

                let response = try await callLLM(request, emit: emit)
                let parsed = try OutputParser.parse(response)

                switch parsed {
                case .final(let text):
                    try await guardrails.verify(.finalResult, .finalResult(text))
                    emit(.verification(stage: .finalResult, outcome: .pass))
                    try? await memory.append(UsageEvent(
                        viewID: viewID, kind: .llmResponse, text: text
                    ))
                    emit(.finalAnswer(text))
                    return

                case .toolCalls(let calls), .mixed(_, let calls):
                    transcript.append(.assistant(response.content))
                    for call in calls {
                        try await execute(
                            call, viewID: viewID, transcript: &transcript, emit: emit
                        )
                    }
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
        emit(.error(IterationLimitExceeded(limit: options.maxIterations)))
    }

    // MARK: - Tool execution

    private func execute(
        _ call: ToolCall,
        viewID: ViewContext.ID,
        transcript: inout [TranscriptEntry],
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws {
        try await guardrails.verify(.preToolUse, .preToolUse(call))
        emit(.verification(stage: .preToolUse, outcome: .pass))

        let inputData = (try? call.input.data()) ?? Data("{}".utf8)
        emit(.toolCall(name: call.name, input: inputData))
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .toolInvoked,
            text: "\(call.name) \(String(decoding: inputData, as: UTF8.self))"
        ))

        let context = ToolContext(viewID: viewID, memory: memory, logger: logger)
        let output: Data
        do {
            output = try await tools.invoke(
                name: call.name, jsonInput: inputData, context: context
            )
        } catch {
            // Surface to the catch-site classifier (tool-retriable, fatal, …).
            throw error
        }

        let isError = false
        try await guardrails.verify(
            .postToolUse,
            .postToolUse(name: call.name, output: output, isError: isError)
        )
        emit(.verification(stage: .postToolUse, outcome: .pass))
        emit(.toolResult(name: call.name, output: output))
        try? await memory.append(UsageEvent(
            viewID: viewID, kind: .toolResult,
            text: "\(call.name) -> \(String(decoding: output, as: UTF8.self))"
        ))

        transcript.append(.toolResult(
            id: call.id ?? call.name,
            name: call.name,
            content: String(decoding: output, as: UTF8.self),
            isError: isError
        ))
    }

    // MARK: - LLM

    private func callLLM(
        _ request: LLMRequest,
        emit: @Sendable (OrchestratorEvent) -> Void
    ) async throws -> LLMResponse {
        guard options.stream else {
            return try await llm.complete(request)
        }
        var text = ""
        var toolBlocks: [(id: String, name: String, json: String)] = []
        var stopReason: StopReason = .endTurn
        var usage = TokenUsage.zero

        for try await chunk in llm.stream(request) {
            switch chunk {
            case .textDelta(let delta):
                text += delta
                emit(.llmDelta(delta))
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
                usage = value
            }
        }

        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        for tool in toolBlocks {
            let input: JSONValue
            if let data = tool.json.data(using: .utf8),
               let value = try? JSONValue(data: data) {
                input = value
            } else {
                input = .object([:])
            }
            blocks.append(.toolUse(id: tool.id, name: tool.name, input: input))
        }
        return LLMResponse(content: blocks, stopReason: stopReason, usage: usage)
    }
}
