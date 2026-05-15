import Foundation
import AIKitCore
import AIKitCapability

/// Decides what to do with an error mid-turn, applying backoff for retries.
public actor ErrorHandler {
    public enum Decision: Sendable {
        case retry
        case fallback(prompt: String)
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

        case .malformedOutput:
            let detail: String
            if case OutputParser.ParserError.malformedToolInput(let name, let raw) = error {
                detail = "Your previous tool call to '\(name)' had malformed JSON input: \(raw)."
            } else {
                detail = "Your previous response could not be parsed."
            }
            return .fallback(prompt:
                "\(detail) Re-issue the tool call with valid JSON matching the schema, "
                + "or give a final answer.")

        case .transient, .toolRetriable:
            guard policy.retriableCategories.contains(category),
                  attempt < policy.maxAttempts else {
                return .abort(error)
            }
            let delay = policy.backoff.delay(forAttempt: attempt)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if category == .toolRetriable {
                let message = (error as? any ToolError).map { "\($0)" } ?? "\(error)"
                return .fallback(prompt:
                    "The tool failed but may succeed on retry: \(message). Try again.")
            }
            return .retry
        }
    }
}

/// Raised when the orchestration loop exceeds its iteration budget.
public struct IterationLimitExceeded: Error, Sendable {
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}
