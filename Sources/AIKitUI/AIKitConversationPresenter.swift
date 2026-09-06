import Foundation
import FoundationModels
import Observation
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety

/// Presentation over one conversation. `lines` contains validated transcript
/// projections; pendingPrompt and lastError are separate transient state.
/// isResponding covers admission through settlement, and totalUsage refreshes
/// from the official cumulative session usage at settlement. Use one presenter
/// per UI conversation owner; direct session calls are an explicit escape hatch.
@MainActor
@Observable
public final class AIKitConversationPresenter {
    /// One transcript line, derived from an official entry.
    public struct Line: Identifiable, Sendable {
        public enum Role: String, Sendable {
            case user
            case assistant
            case reasoning
            case toolCall
            case toolOutput
            case error
        }

        /// The official transcript entry id (stable across derivations), or
        /// a locally unique id for lines without an entry (errors).
        public let id: String
        public let role: Role
        public let text: String
    }

    public private(set) var lines: [Line] = []
    /// Compatibility surface: validated delivery holds provisional text back.
    public private(set) var streamingText: String = ""
    /// Compatibility surface: reasoning appears in accepted transcript lines.
    public private(set) var reasoningText: String = ""
    public private(set) var isResponding = false
    public private(set) var lastError: String?
    public private(set) var pendingPrompt: String?
    /// The official cumulative session usage, in AIKit's persistable shape.
    public private(set) var totalUsage = TokenUsage.zero

    public let conversation: AIKitConversation

    public init(conversation: AIKitConversation) {
        self.conversation = conversation
        self.lines = Self.deriveLines(from: conversation.validatedTranscript)
        self.totalUsage = TokenUsage(conversation.session.usage)
    }

    /// Maps a turn error to a user-facing string.
    nonisolated static func describe(_ error: any Error) -> String {
        let error = ErrorClassifier.underlyingError(error)
        if let modelError = error as? LanguageModelError,
           case .guardrailViolation(let violation) = modelError {
            return violation.debugDescription
        }
        if let refusal = error as? TurnRefusal {
            return refusal.reason
        }
        if let deadline = error as? TurnDeadlineExceeded {
            return "Stopped after exceeding the \(Int(deadline.budget))s turn budget."
        }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    /// Runs one turn on the official streaming path. Ignored while a turn
    /// is already in flight (the UI's send control should be disabled by
    /// `isResponding` anyway).
    public func send(
        _ instruction: String,
        options: GenerationOptions = GenerationOptions()
    ) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        let session = conversation.session
        isResponding = true
        lastError = nil
        streamingText = ""
        reasoningText = ""

        // Keep draft/error presentation separate from the official history.
        // No generated text or tool output is exposed until all rails pass.
        pendingPrompt = trimmed
        defer {
            pendingPrompt = nil
            streamingText = ""
            reasoningText = ""
            totalUsage = TokenUsage(session.usage)
            isResponding = false
        }
        do {
            _ = try await conversation.collectResponse(to: trimmed, options: options)
            lines = Self.deriveLines(from: conversation.validatedTranscript)
        } catch {
            if !(error is CancellationError) { lastError = Self.describe(error) }
        }
    }

    // MARK: - Transcript projection

    /// UI lines are a pure projection of the official transcript — one line
    /// per user-visible entry, tool calls and outputs exactly once, in
    /// transcript order.
    static func deriveLines(from transcript: Transcript) -> [Line] {
        transcript.flatMap { entry -> [Line] in
            switch entry {
            case .prompt(let prompt):
                [Line(id: prompt.id, role: .user, text: prompt.contentText)]
            case .response(let response):
                response.contentText.isEmpty
                    ? []
                    : [Line(id: response.id, role: .assistant, text: response.contentText)]
            case .reasoning(let reasoning):
                reasoning.contentText.isEmpty
                    ? []
                    : [Line(id: reasoning.id, role: .reasoning, text: reasoning.contentText)]
            case .toolCalls(let calls):
                calls.map { call in
                    Line(id: call.id, role: .toolCall, text: call.toolName)
                }
            case .toolOutput(let output):
                [Line(
                    id: output.id,
                    role: .toolOutput,
                    text: "\(output.toolName): \(output.contentText)"
                )]
            case .instructions:
                []
            @unknown default:
                []
            }
        }
    }

    /// The in-flight turn's reasoning, recovered from the official snapshot
    /// entries (the session surface exposes reasoning only there).
    private static func reasoningText(
        in entries: ArraySlice<Transcript.Entry>
    ) -> String {
        entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            let text = reasoning.contentText
            return text.isEmpty ? nil : text
        }.joined()
    }
}
