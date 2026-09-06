import Foundation
import FoundationModels
import Synchronization

/// A scripted official `LanguageModel` for tests.
///
/// Each `LanguageModelSession` round consumes the next scripted response:
/// the executor replays it into the official generation channel exactly the
/// way a real provider package does (text fragments, reasoning fragments,
/// tool-call announcements with streamed arguments, a `finishReason`
/// metadata entry, and one final usage update). A turn that scripts tool
/// calls makes the session execute those tools and come back for the next
/// scripted response — so the mock exercises the same native tool loop the
/// shipped models use.
public struct MockLanguageModel: LanguageModel, Sendable {
    public typealias Executor = MockLanguageModelExecutor

    /// One scripted tool call.
    public struct ToolCall: Sendable {
        public var id: String
        public var name: String
        public var argumentsJSON: String

        public init(
            id: String = UUID().uuidString,
            name: String,
            argumentsJSON: String = "{}"
        ) {
            self.id = id
            self.name = name
            self.argumentsJSON = argumentsJSON
        }
    }

    /// One scripted model round: prose, optional reasoning, tool calls, and
    /// the usage the round reports.
    public struct Turn: Sendable {
        public var text: String
        public var reasoning: String?
        public var toolCalls: [ToolCall]
        public var inputTokens: Int
        public var outputTokens: Int

        public init(
            text: String = "",
            reasoning: String? = nil,
            toolCalls: [ToolCall] = [],
            inputTokens: Int = 0,
            outputTokens: Int = 0
        ) {
            self.text = text
            self.reasoning = reasoning
            self.toolCalls = toolCalls
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    /// Thrown when a session asks for more rounds than were scripted.
    public struct Exhausted: Error, Sendable {}

    /// `LanguageModelExecutor.Configuration` must be `Hashable`; the script
    /// itself lives in a process-global registry keyed by this id.
    public struct Configuration: Sendable, Hashable {
        let scriptID: UUID
    }

    public let capabilities: LanguageModelCapabilities
    private let configuration: Configuration

    public var executorConfiguration: Configuration { configuration }

    public static let defaultCapabilities = LanguageModelCapabilities(
        [.toolCalling, .reasoning, .guidedGeneration]
    )

    public init(
        results: [Result<Turn, any Error>],
        capabilities: LanguageModelCapabilities = Self.defaultCapabilities
    ) {
        self.capabilities = capabilities
        self.configuration = Configuration(scriptID: MockScriptRegistry.register(results))
    }

    public init(
        turns: [Turn],
        capabilities: LanguageModelCapabilities = Self.defaultCapabilities
    ) {
        self.init(
            results: turns.map { .success($0) },
            capabilities: capabilities
        )
    }

    /// Convenience: a single final-text round.
    public init(finalText: String) {
        self.init(turns: [Turn(text: finalText)])
    }

    /// Every generation request the model has received, in order — one per
    /// session round, carrying the official transcript, enabled tools,
    /// schema, and options.
    public var receivedRequests: [LanguageModelExecutorGenerationRequest] {
        MockScriptRegistry.requests(for: configuration.scriptID)
    }
}

public struct MockLanguageModelExecutor: LanguageModelExecutor, Sendable {
    public typealias Configuration = MockLanguageModel.Configuration
    public typealias Model = MockLanguageModel

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model: MockLanguageModel, transcript: Transcript) {}

    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: MockLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let turn = try MockScriptRegistry.next(
            for: configuration.scriptID, recording: request
        )
        let entryID = UUID().uuidString

        if let reasoning = turn.reasoning, !reasoning.isEmpty {
            await channel.send(.reasoning(
                entryID: entryID,
                action: .appendText(reasoning, tokenCount: 1)
            ))
        }
        if !turn.text.isEmpty {
            await channel.send(.response(
                entryID: entryID,
                action: .appendText(turn.text, tokenCount: 1)
            ))
        }
        for call in turn.toolCalls {
            // Announce the call (id + name before any argument bytes), then
            // stream the arguments — the grammar real providers use.
            await channel.send(.toolCalls(
                entryID: entryID,
                action: .toolCall(
                    id: call.id,
                    name: call.name,
                    action: .appendArguments("", tokenCount: 0)
                )
            ))
            await channel.send(.toolCalls(
                entryID: entryID,
                action: .toolCall(
                    id: call.id,
                    name: call.name,
                    action: .appendArguments(call.argumentsJSON, tokenCount: 1)
                )
            ))
        }
        await channel.send(.response(
            entryID: entryID,
            action: .updateMetadata([
                "finishReason": turn.toolCalls.isEmpty ? "stop" : "tool_calls",
            ])
        ))
        await channel.send(.response(
            entryID: entryID,
            action: .updateUsage(
                input: .init(totalTokenCount: turn.inputTokens, cachedTokenCount: 0),
                output: .init(totalTokenCount: turn.outputTokens, reasoningTokenCount: 0)
            )
        ))
    }
}

/// Process-global script storage. `LanguageModelExecutor` configurations are
/// `Hashable` value types, so the mutable script state lives here, keyed by
/// the model's script id.
private enum MockScriptRegistry {
    private struct Script {
        var results: [Result<MockLanguageModel.Turn, any Error>]
        var index = 0
        var requests: [LanguageModelExecutorGenerationRequest] = []
    }

    private static let scripts = Mutex<[UUID: Script]>([:])

    static func register(
        _ results: [Result<MockLanguageModel.Turn, any Error>]
    ) -> UUID {
        let id = UUID()
        scripts.withLock { $0[id] = Script(results: results) }
        return id
    }

    static func next(
        for id: UUID,
        recording request: LanguageModelExecutorGenerationRequest
    ) throws -> MockLanguageModel.Turn {
        try scripts.withLock { scripts in
            guard var script = scripts[id] else {
                throw MockLanguageModel.Exhausted()
            }
            script.requests.append(request)
            defer { scripts[id] = script }
            guard script.index < script.results.count else {
                throw MockLanguageModel.Exhausted()
            }
            let result = script.results[script.index]
            script.index += 1
            return try result.get()
        }
    }

    static func requests(for id: UUID) -> [LanguageModelExecutorGenerationRequest] {
        scripts.withLock { $0[id]?.requests ?? [] }
    }
}
