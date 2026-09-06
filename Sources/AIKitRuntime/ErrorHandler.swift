import Foundation

/// Pure retry decision. The admitted turn owns cancellable backoff timing.
///
/// Malformed tool arguments surface as parsing errors. Replaying a turn
/// requires explicit host authorization through the retry policy.
public actor ErrorHandler {
    public enum Decision: Sendable {
        case retry(delay: TimeInterval)
        case abort(any Error)
    }

    public init() {}

    public func handle(
        _ error: any Error,
        attempt: Int,
        policy: RetryPolicy
    ) async -> Decision {
        let category = ErrorClassifier.category(of: error)

        switch category {
        case .guardrailViolation, .fatal:
            return .abort(error)

        case .transient, .toolRetriable:
            guard policy.retriableCategories.contains(category),
                  attempt < policy.maxAttempts else {
                return .abort(error)
            }
            return .retry(delay: policy.backoff.delay(forAttempt: attempt))
        }
    }
}

/// Thrown by the runtime's guarded tool layer when the model calls the
/// built-in `reportFailure` escape hatch: the turn ends in a failure state
/// carrying the model's reason instead of a final answer.
public struct TurnRefusal: Error, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Raised when a turn exceeds `Orchestrator.Options.maxTurnDuration`. Aborts
/// rather than letting transient-classified timeouts retry past the budget.
public struct TurnDeadlineExceeded: Error, Sendable {
    /// The configured budget, in seconds.
    public let budget: TimeInterval
    public init(budget: TimeInterval) { self.budget = budget }
}
