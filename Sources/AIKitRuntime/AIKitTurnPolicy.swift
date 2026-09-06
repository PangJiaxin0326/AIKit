import Foundation
import FoundationModels

/// The optional host policies around one conversation's turns — retry,
/// deadline, same-conversation concurrency, and transcript error handling.
/// Everything the model pipeline itself owns (instructions, tools, model,
/// generation configuration, the tool loop) lives on the profile and the
/// official session; this is deliberately only what the framework does not
/// provide.
public struct AIKitTurnPolicy: Sendable {
    /// What happens when a second turn is sent while one is in flight on the
    /// same conversation. A single official session must never generate
    /// overlapping responses, so the choice is explicit.
    public enum OverlapPolicy: Sendable, Hashable {
        /// Queue the turn until the in-flight one finishes.
        case serialize
        /// Throw `AIKitConversationError.overlappingTurn` immediately.
        case reject
    }

    /// Turn-level retry for transient failures. Retries re-send on the SAME
    /// session after the framework applies `transcriptErrorHandling` — with
    /// the default `.revertTranscript`, a failed attempt leaves no residue.
    /// Retries cannot undo an external tool side effect: keep tools
    /// idempotent, or classify errors so retry stops after irreversible
    /// work. Guardrail violations and refusals never retry.
    public var retry: RetryPolicy

    /// A cooperative execution budget for the whole turn (all session rounds and
    /// retries combined). `nil` (default) is unbounded. The budget covers model calls and backoff, starting after admission.
    /// Queueing and essential settlement are excluded. Cancellation waits for
    /// tool cleanup; a noncooperative tool can exceed the budget.
    public var deadline: TimeInterval?

    public var overlap: OverlapPolicy

    /// Applied to the session explicitly at conversation setup, per the
    /// migration contract: the default `.revertTranscript` rolls a failed
    /// attempt out of the transcript (suitable for retries);
    /// `.preserveTranscript` keeps it, and makes any retry the host's
    /// responsibility to repair first.
    public enum TranscriptRecovery: Sendable, Equatable {
        case revertTranscript
        case preserveTranscript
        var official: TranscriptErrorHandlingPolicy {
            switch self {
            case .revertTranscript: .revertTranscript
            case .preserveTranscript: .preserveTranscript
            }
        }
    }
    public var transcriptErrorHandling: TranscriptRecovery
    /// Required for automatic retry with preserved history. Executes inside
    /// the deadline; the host repairs history/state before the next attempt.
    public var prepareForRetry: (@Sendable (LanguageModelSession) async throws -> Void)?

    public init(
        retry: RetryPolicy = .never,
        deadline: TimeInterval? = nil,
        overlap: OverlapPolicy = .serialize,
        transcriptErrorHandling: TranscriptRecovery = .revertTranscript,
        prepareForRetry: (@Sendable (LanguageModelSession) async throws -> Void)? = nil
    ) {
        self.retry = retry
        self.deadline = deadline
        self.overlap = overlap
        self.transcriptErrorHandling = transcriptErrorHandling
        self.prepareForRetry = prepareForRetry
    }
}

/// Errors the conversation boundary itself raises. Session and model errors
/// propagate as their official types.
public enum AIKitConversationError: Error, Sendable, Hashable, LocalizedError {
    /// The turn policy is `.reject` and a turn is already in flight.
    case overlappingTurn
    case invalidDeadline

    public var errorDescription: String? {
        switch self {
        case .invalidDeadline:
            String(localized: "The turn deadline must be a positive, finite number.")
        case .overlappingTurn:
            String(localized: "The conversation is already responding.")
        }
    }
}
