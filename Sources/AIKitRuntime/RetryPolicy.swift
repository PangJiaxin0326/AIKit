import Foundation
import AIKitCore
import AIKitCapability
import AIKitSafety

/// How an error is classified for retry decisions.
public enum ErrorCategory: Sendable, Hashable {
    case transient            // network blip, 5xx
    case toolRetriable        // tool said isRetriable == true
    case malformedOutput      // parser failure
    case guardrailViolation   // never retriable
    case fatal
}

public struct RetryPolicy: Sendable, Hashable {
    public enum Backoff: Sendable, Hashable {
        case none
        case fixed(seconds: Double)
        case exponential(base: Double, cap: Double)

        public func delay(forAttempt attempt: Int) -> Double {
            switch self {
            case .none:
                return 0
            case .fixed(let seconds):
                return seconds
            case .exponential(let base, let cap):
                return min(cap, base * pow(2, Double(max(0, attempt - 1))))
            }
        }
    }

    public var maxAttempts: Int
    public var backoff: Backoff
    public var retriableCategories: Set<ErrorCategory>

    public init(
        maxAttempts: Int = 3,
        backoff: Backoff = .exponential(base: 0.4, cap: 4.0),
        retriableCategories: Set<ErrorCategory> = [.transient, .toolRetriable]
    ) {
        self.maxAttempts = maxAttempts
        self.backoff = backoff
        self.retriableCategories = retriableCategories
    }

    public static let `default` = RetryPolicy()
}

/// Classifies an error into an `ErrorCategory`.
public enum ErrorClassifier {
    public static func category(of error: any Error) -> ErrorCategory {
        switch error {
        case is GuardrailViolation:
            return .guardrailViolation
        case let toolError as any ToolError:
            return toolError.isRetriable ? .toolRetriable : .fatal
        case is OutputParser.ParserError:
            return .malformedOutput
        case let llmError as LLMError:
            switch llmError {
            case .httpStatus(let code, _):
                return (500..<600).contains(code) ? .transient : .fatal
            case .transport:
                return .transient
            default:
                return .fatal
            }
        default:
            return .fatal
        }
    }
}
