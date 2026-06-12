import Foundation
import FoundationModels
import AIToolKit

/// `LLMProvider` backed by any Foundation Models `LanguageModel`.
///
/// The runtime keeps its own loop (guardrails, retries, deadlines, memory),
/// so this adapter drives the model's `LanguageModelExecutor` directly through
/// the official request/channel API instead of a `LanguageModelSession`: one
/// `LLMRequest` becomes one `Transcript` + generation request, and the
/// channel's events stream back as `LLMResponseChunk`s. Provider packages
/// keep their wire mapping in exactly one place — their executor.
public struct LanguageModelProvider<M: LanguageModel>: LLMProvider {
    public let configuration: LLMProviderConfiguration
    public var providerName: String { name }
    public var supportsNativeTools: Bool { nativeTools }

    private let name: String
    private let nativeTools: Bool
    private let makeModel: @Sendable (String) -> M
    private let makeExecutor: @Sendable (M) throws -> M.Executor
    private let mapError: @Sendable (any Error) -> LLMError?

    /// - Parameters:
    ///   - makeModel: Builds the model value for one request's model id. The
    ///     Foundation Models paradigm bakes the model id into the model value,
    ///     so per-request selection means constructing a new value.
    ///   - makeExecutor: Builds the executor for a model. Defaults to the
    ///     official `init(configuration:)`; override to inject transport
    ///     details the official initializer can't carry (e.g. a stubbed
    ///     `URLSession` in tests).
    ///   - mapError: Maps provider-package errors onto the `LLMError`
    ///     taxonomy the runtime's retry classification keys on. Errors it
    ///     returns `nil` for fall back to the official
    ///     `LanguageModelError` mapping.
    public init(
        configuration: LLMProviderConfiguration,
        providerName: String? = nil,
        makeModel: @escaping @Sendable (String) -> M,
        makeExecutor: @escaping @Sendable (M) throws -> M.Executor = { model in
            try M.Executor(configuration: model.executorConfiguration)
        },
        mapError: @escaping @Sendable (any Error) -> LLMError? = { _ in nil }
    ) {
        self.configuration = configuration
        self.name = providerName ?? String(describing: M.self)
        self.nativeTools = makeModel(configuration.defaultModel ?? "")
            .capabilities.contains(.toolCalling)
        self.makeModel = makeModel
        self.makeExecutor = makeExecutor
        self.mapError = mapError
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var textChunks: [String] = []
        var reasoningChunks: [String] = []
        var toolBlocks: [StreamedToolBlock] = []
        var toolIndexesByID: [String: Int] = [:]
        var stopReason: StopReason = .endTurn
        var usage = TokenUsage.zero

        for try await chunk in stream(request) {
            switch chunk {
            case .textDelta(let delta):
                textChunks.append(delta)
            case .reasoningDelta(let delta):
                reasoningChunks.append(delta)
            case .toolUseStart(let id, let name):
                toolIndexesByID[id] = toolBlocks.count
                toolBlocks.append(StreamedToolBlock(id: id, name: name))
            case .toolUseInputDelta(let id, let json):
                if let index = toolIndexesByID[id] {
                    toolBlocks[index].jsonChunks.append(json)
                }
            case .toolUseStop:
                continue
            case .stop(let reason):
                stopReason = reason
            case .usage(let value):
                usage = TokenUsage(
                    inputTokens: max(usage.inputTokens, value.inputTokens),
                    outputTokens: max(usage.outputTokens, value.outputTokens)
                )
            }
        }

        var blocks: [ContentBlock] = []
        let reasoning = reasoningChunks.joined()
        if !reasoning.isEmpty { blocks.append(.reasoning(reasoning)) }
        let text = textChunks.joined()
        if !text.isEmpty { blocks.append(.text(text)) }
        for tool in toolBlocks {
            let json = tool.jsonChunks.joined()
            let arguments: GeneratedContent
            if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments = .object([:])
            } else if AIKitMalformedToolInput.isCompleteJSON(json),
                      let value = try? GeneratedContent(json: json) {
                arguments = value
            } else {
                arguments = AIKitMalformedToolInput.make(raw: json)
            }
            blocks.append(.toolUse(id: tool.id, name: tool.name, arguments: arguments))
        }
        return LLMResponse(content: blocks, stopReason: stopReason, usage: usage)
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await relay(request) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: resolveError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Channel relay

    /// The drain loop's stand-in for the channel finish the official API
    /// doesn't expose: the executor task posts this entry id after `respond`
    /// returns (or throws), so iteration always ends.
    private static var endOfStreamEntryID: String { "aikit.language-model-provider.end" }

    private func relay(
        _ request: LLMRequest,
        yield: @escaping @Sendable (LLMResponseChunk) -> Void
    ) async throws {
        let model = makeModel(request.model)
        let executor = try makeExecutor(model)
        let generationRequest = LanguageModelExecutorGenerationRequest(
            id: UUID(),
            transcript: try Self.transcript(from: request),
            enabledTools: request.tools.map {
                Transcript.ToolDefinition(
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.argumentsSchema
                )
            },
            schema: request.responseSchema,
            generationOptions: GenerationOptions(
                temperature: request.temperature,
                maximumResponseTokens: request.maxTokens
            ),
            contextOptions: ContextOptions(),
            metadata: [:]
        )
        let channel = LanguageModelExecutorGenerationChannel()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await executor.respond(
                        to: generationRequest, model: model, streamingInto: channel
                    )
                } catch {
                    await channel.send(.response(
                        entryID: Self.endOfStreamEntryID, action: .updateMetadata([:])
                    ))
                    throw error
                }
                await channel.send(.response(
                    entryID: Self.endOfStreamEntryID, action: .updateMetadata([:])
                ))
            }

            var openToolIDs: [String] = []
            var seenToolIDs: Set<String> = []
            var usage: TokenUsage?
            var finishReason: String?

            for try await event in channel {
                if let response = event as? LanguageModelExecutorGenerationChannel.Response {
                    if response.entryID == Self.endOfStreamEntryID { break }
                    switch response.action {
                    case .appendText(let fragment):
                        if !fragment.content.isEmpty { yield(.textDelta(fragment.content)) }
                    case .updateMetadata(let metadata):
                        if let reason = metadata.values["finishReason"] as? String {
                            finishReason = reason
                        }
                    case .updateUsage(let value):
                        usage = Self.merged(usage, with: value)
                    default:
                        continue
                    }
                } else if let reasoning = event as? LanguageModelExecutorGenerationChannel.Reasoning {
                    switch reasoning.action {
                    case .appendText(let fragment):
                        if !fragment.content.isEmpty { yield(.reasoningDelta(fragment.content)) }
                    case .updateUsage(let value):
                        usage = Self.merged(usage, with: value)
                    default:
                        continue
                    }
                } else if let toolCalls = event as? LanguageModelExecutorGenerationChannel.ToolCalls {
                    switch toolCalls.action {
                    case .toolCall(let call):
                        if seenToolIDs.insert(call.id).inserted {
                            openToolIDs.append(call.id)
                            yield(.toolUseStart(id: call.id, name: call.name))
                        }
                        if case .appendArguments(let fragment) = call.action,
                           !fragment.content.isEmpty {
                            yield(.toolUseInputDelta(id: call.id, json: fragment.content))
                        }
                    case .updateUsage(let value):
                        usage = Self.merged(usage, with: value)
                    default:
                        continue
                    }
                }
            }
            try await group.next()

            for id in openToolIDs { yield(.toolUseStop(id: id)) }
            if let usage { yield(.usage(usage)) }
            yield(.stop(Self.stopReason(
                finishReason: finishReason,
                sawToolCalls: !openToolIDs.isEmpty
            )))
        }
    }

    private func resolveError(_ error: any Error) -> any Error {
        if let mapped = mapError(error) { return mapped }
        if let llmError = error as? LLMError { return llmError }
        if let official = error as? LanguageModelError {
            switch official {
            case .rateLimited:
                return LLMError.httpStatus(code: 429, body: official.localizedDescription)
            case .timeout:
                return LLMError.timeout(official.localizedDescription)
            default:
                return LLMError.provider(message: official.localizedDescription)
            }
        }
        return LLMError.provider(message: String(describing: error))
    }

    private static func merged(
        _ usage: TokenUsage?,
        with value: LanguageModelExecutorGenerationChannel.Usage
    ) -> TokenUsage {
        let current = usage ?? .zero
        return TokenUsage(
            inputTokens: max(current.inputTokens, value.input.totalTokenCount),
            outputTokens: max(current.outputTokens, value.output.totalTokenCount)
        )
    }

    private static func stopReason(finishReason: String?, sawToolCalls: Bool) -> StopReason {
        switch finishReason {
        case "stop":
            .endTurn
        case "tool_calls":
            .toolUse
        case "length":
            .maxTokens
        case let other?:
            .other(other)
        case nil:
            sawToolCalls ? .toolUse : .endTurn
        }
    }

    // MARK: - Transcript construction

    /// System text rides `instructions`; user turns carry text and image
    /// attachments; assistant turns split into `response` (text) and
    /// `toolCalls` entries; tool results become `toolOutput`. Reasoning
    /// blocks never re-enter the transcript.
    private static func transcript(from request: LLMRequest) throws -> Transcript {
        var entries: [Transcript.Entry] = []
        if let system = request.system, !system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: system))],
                toolDefinitions: []
            )))
        }
        for message in request.messages {
            switch message.role {
            case .system:
                guard message.images.isEmpty else {
                    throw LLMError.unsupported("System messages support text only.")
                }
                let text = message.plainText
                guard !text.isEmpty else { continue }
                entries.append(.instructions(Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: text))],
                    toolDefinitions: []
                )))
            case .user:
                let segments = try promptSegments(for: message)
                guard !segments.isEmpty else { continue }
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant:
                let text = message.plainText
                if !text.isEmpty {
                    entries.append(.response(Transcript.Response(
                        assetIDs: [],
                        segments: [.text(Transcript.TextSegment(content: text))]
                    )))
                }
                let calls = message.content.compactMap { block -> Transcript.ToolCall? in
                    guard case .toolUse(let id, let name, let arguments) = block else {
                        return nil
                    }
                    return Transcript.ToolCall(id: id, toolName: name, arguments: arguments)
                }
                if !calls.isEmpty {
                    entries.append(.toolCalls(Transcript.ToolCalls(calls)))
                }
            case .tool:
                for block in message.content {
                    guard case .toolResult(let toolUseID, let content, _) = block else {
                        continue
                    }
                    entries.append(.toolOutput(Transcript.ToolOutput(
                        id: toolUseID,
                        toolName: "",
                        segments: [.text(Transcript.TextSegment(content: content))]
                    )))
                }
            }
        }
        return Transcript(entries: entries)
    }

    private static func promptSegments(for message: Message) throws -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        for block in message.content {
            switch block {
            case .text(let text):
                if !text.isEmpty {
                    segments.append(.text(Transcript.TextSegment(content: text)))
                }
            case .reasoning:
                continue
            case .image(let image):
                guard let url = imageURL(for: image) else {
                    throw LLMError.unsupported("Image attachment could not be encoded as a URL.")
                }
                // The label carries the requested fidelity; providers whose
                // wire has a `detail` field recover it from there.
                segments.append(.attachment(Transcript.AttachmentSegment(
                    content: .image(Transcript.ImageAttachment(imageURL: url)),
                    label: image.detail?.rawValue
                )))
            case .toolUse, .toolResult:
                continue
            }
        }
        return segments
    }

    private static func imageURL(for image: ImageContent) -> URL? {
        switch image.source {
        case .url(let url):
            url
        case .data(let mimeType, let data):
            URL(string: "data:\(mimeType);base64,\(data.base64EncodedString())")
        }
    }
}

private struct StreamedToolBlock {
    let id: String
    let name: String
    var jsonChunks: [String] = []
}
