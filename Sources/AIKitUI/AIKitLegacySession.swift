import Foundation
import FoundationModels
import SwiftUI
import Observation
import AIToolKit
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import UICollection
#endif
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety
import MultiModalKit

struct AIKitStreamingTextAccumulator {
    private var renderedText = ""
    private var pendingChunks: [String] = []
    private var pendingBytes = 0
    private let flushThreshold = 512

    var isEmpty: Bool { renderedText.isEmpty && pendingChunks.isEmpty }

    mutating func append(_ delta: String) -> String? {
        guard !delta.isEmpty else { return nil }
        pendingChunks.append(delta)
        pendingBytes += delta.utf8.count
        guard pendingBytes >= flushThreshold else { return nil }
        return flush()
    }

    mutating func flush() -> String {
        if !pendingChunks.isEmpty {
            renderedText += pendingChunks.joined()
            pendingChunks.removeAll(keepingCapacity: true)
        }
        pendingBytes = 0
        return renderedText
    }
}

/// Drives one `Orchestrator` turn and exposes its events for SwiftUI.
///
/// **Deprecated with `Orchestrator`.** `AIKitConversationPresenter` is the
/// replacement: lines derived from the official transcript, streaming from
/// the official response stream, no parallel event taxonomy.
@MainActor
@Observable
public final class AIKitSession {
    public struct Line: Identifiable, Sendable {
        public let id = UUID()
        public let role: String
        public let text: String
    }

    public private(set) var streamingText: String = ""
    /// Live model reasoning for the in-flight turn. Cleared when the final
    /// answer arrives. Empty when the model emits no reasoning.
    public private(set) var reasoningText: String = ""
    public private(set) var lines: [Line] = []
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Cumulative token usage across every turn this session has run.
    public private(set) var totalUsage = TokenUsage.zero

    private let orchestrator: Orchestrator

    public init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    /// Maps a turn error to a user-facing string. `nonisolated` so the
    /// voice mode can reuse it off the main actor.
    nonisolated static func describe(_ error: any Error) -> String {
        if let modelError = error as? LanguageModelError,
           case .guardrailViolation(let violation) = modelError {
            return AIKitUILocalization.string("\(violation.debugDescription)")
        }
        if let deadline = error as? TurnDeadlineExceeded {
            return AIKitUILocalization.string(
                "Stopped after exceeding the \(Int(deadline.budget))s turn budget."
            )
        }
        if let configuration = error as? AIKitConfigurationError {
            return configuration.message
        }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    public func send(_ instruction: String) async {
        await send(instruction) { orchestrator, trimmed in
            await orchestrator.run(trimmed)
        }
    }

    /// Runs the turn through a host-authored `DynamicProfile` instead of the
    /// orchestrator's synthesized one (`Orchestrator.run(_:profile:)`): the
    /// profile owns the turn's instructions and tools; the transcript lines,
    /// streaming text, usage, and error handling are identical to `send(_:)`.
    /// Pass a bare profile — the orchestrator applies its own model and
    /// generation options.
    public func send<Profile: LanguageModelSession.DynamicProfile & Sendable>(
        _ instruction: String,
        profile: Profile
    ) async {
        await send(instruction) { orchestrator, trimmed in
            await orchestrator.run(trimmed, profile: profile)
        }
    }

    private func send(
        _ instruction: String,
        makeStream: (Orchestrator, String) async -> AsyncThrowingStream<OrchestratorEvent, any Error>
    ) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        isRunning = true
        lastError = nil
        streamingText = ""
        reasoningText = ""
        lines.append(Line(role: "you", text: trimmed))
        var streamingBuffer = AIKitStreamingTextAccumulator()
        var reasoningBuffer = AIKitStreamingTextAccumulator()

        // Surface whatever is still buffered before recording a terminal
        // line, so a sub-flush-threshold tail isn't dropped when the turn ends.
        func flushStreamingBuffers() {
            if !streamingBuffer.isEmpty {
                streamingText = streamingBuffer.flush()
            }
            if !reasoningBuffer.isEmpty {
                reasoningText = reasoningBuffer.flush()
            }
        }

        do {
            for try await event in await makeStream(orchestrator, trimmed) {
                switch event {
                case .llmDelta(let delta):
                    if let text = streamingBuffer.append(delta) {
                        streamingText = text
                    }
                case .reasoningDelta(let delta):
                    if let text = reasoningBuffer.append(delta) {
                        reasoningText = text
                    }
                case .toolCall(let call):
                    lines.append(Line(role: "tool", text: "Calling \(call.toolName)"))
                case .toolResult(let call, let output):
                    lines.append(Line(
                        role: "tool",
                        text: "\(call.toolName): \(output.contentText)"
                    ))
                case .verification(let stage, let outcome):
                    switch outcome {
                    case .pass:
                        break
                    case .warn(let reason):
                        lines.append(Line(role: "warn", text: "[\(stage.rawValue)] \(reason)"))
                    case .block(let reason):
                        lines.append(Line(role: "blocked", text: "[\(stage.rawValue)] \(reason)"))
                    }
                case .usage(let usage):
                    totalUsage = TokenUsage(
                        inputTokens: totalUsage.inputTokens + usage.inputTokens,
                        outputTokens: totalUsage.outputTokens + usage.outputTokens,
                        cachedInputTokens: totalUsage.cachedInputTokens + usage.cachedInputTokens,
                        reasoningOutputTokens: totalUsage.reasoningOutputTokens + usage.reasoningOutputTokens
                    )
                case .finalAnswer(let text):
                    flushStreamingBuffers()
                    lines.append(Line(role: "assistant", text: text))
                    streamingText = ""
                    reasoningText = ""
                case .failure(let reason):
                    flushStreamingBuffers()
                    lastError = reason
                    lines.append(Line(role: "failed", text: reason))
                    streamingText = ""
                    reasoningText = ""
                case .error(let error):
                    flushStreamingBuffers()
                    let message = Self.describe(error)
                    lastError = message
                    lines.append(Line(role: "error", text: message))
                case .promptBuilt:
                    break
                }
            }
        } catch {
            flushStreamingBuffers()
            let message = Self.describe(error)
            lastError = message
            lines.append(Line(role: "error", text: message))
        }
        isRunning = false
    }
}

@MainActor
@Observable
final class AssistantInputCoordinator {
    var session: AIKitSession
    var voiceInput = AssistantVoiceInputController()
    var text = ""

    @ObservationIgnored private let orchestrator: Orchestrator
    @ObservationIgnored private var lastInstruction = ""

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
        self.session = AIKitSession(orchestrator: orchestrator)
    }

    func sendCurrentText(activity: OrchestratorActivity) {
        sendText(text, activity: activity)
    }

    func sendText(_ rawText: String, activity: OrchestratorActivity) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !activity.isBusy else { return }
        text = ""
        let instruction = activity.hasFailed
            ? aiKitContextualFollowUpInstruction(
                previous: lastInstruction,
                reason: activity.failureReason,
                followUp: trimmed
            )
            : trimmed
        lastInstruction = trimmed
        Task { await session.send(instruction) }
    }

    func startVoiceRecording(activity: OrchestratorActivity) {
        guard !activity.isBusy, !voiceInput.isVoiceTranscribing else { return }
        text = ""
        voiceInput.startRecording()
    }

    func finishVoiceRecording(activity: OrchestratorActivity) {
        voiceInput.finishRecording { [weak self] text in
            self?.sendText(text, activity: activity)
        }
    }

    func cancelVoiceInput() {
        voiceInput.cancel()
    }

    func clearVoiceError() {
        voiceInput.clearError()
    }

    func cancelCurrentWork() {
        Task { await orchestrator.cancelActiveTurns() }
    }

    func dismissFailure() {
        Task { await orchestrator.cancelActiveTurns() }
    }
}

