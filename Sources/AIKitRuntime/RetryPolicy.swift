import Foundation
import FoundationModels
import AIToolKit

/// How an error is classified for retry decisions.
public enum ErrorCategory: Sendable, Hashable {
    case transient            // network blip, rate limit, 5xx
    case toolRetriable        // tool said isRetriable == true
    case guardrailViolation   // never retriable
    case fatal
}

public struct RetryPolicy: Sendable, Hashable {
    public enum Backoff: Sendable, Hashable {
        case none
        case fixed(seconds: Double)
        case exponential(base: Double, cap: Double)
        /// Exponential backoff with full jitter: a uniformly random delay in
        /// `0...exponential`. Spreads retries so concurrent failures don't
        /// stampede the provider in lockstep.
        case exponentialJitter(base: Double, cap: Double)

        public func delay(forAttempt attempt: Int) -> Double {
            switch self {
            case .none:
                return 0
            case .fixed(let seconds):
                return seconds.isFinite ? max(0, seconds) : 0
            case .exponential(let base, let cap):
                guard base.isFinite, cap.isFinite else { return 0 }
                return max(0, min(cap, base * pow(2, Double(max(0, attempt - 1)))))
            case .exponentialJitter(let base, let cap):
                guard base.isFinite, cap.isFinite else { return 0 }
                let ceiling = min(cap, base * pow(2, Double(max(0, attempt - 1))))
                return Double.random(in: 0...max(0, ceiling))
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

    /// No automatic replay of potentially effectful work.
    public static let never = RetryPolicy(maxAttempts: 1, backoff: .none)

    /// Opt-in: every tool and the host operation must be safe to repeat.
    public static let `default` = RetryPolicy()
}

/// Classifies an error into an `ErrorCategory`. Models surface the official
/// `LanguageModelError` taxonomy; provider-specific shapes (Ark HTTP/transport
/// errors, Private Cloud Compute network failures) are classified on their
/// own types.
public enum ErrorClassifier {
    public static func underlyingError(_ error: any Error) -> any Error {
        if let wrapped = error as? LanguageModelSession.ToolCallError {
            return underlyingError(wrapped.underlyingError)
        }
        return error
    }

    public static func category(of error: any Error) -> ErrorCategory {
        switch error {
        // An error thrown inside a tool's `call` (or a profile hook) reaches
        // the host wrapped in the official `ToolCallError` — classify what it
        // wraps.
        case let toolCallError as LanguageModelSession.ToolCallError:
            return category(of: toolCallError.underlyingError)
        // Model-authored content that failed a strict typed decode (tool
        // arguments, guided generation). A fresh attempt re-prompts the
        // model, which can emit it correctly — worth a retry.
        case is GeneratedContent.ParsingError:
            return .transient
        case let toolError as any ToolError:
            return toolError.isRetriable ? .toolRetriable : .fatal
        case let modelError as LanguageModelError:
            switch modelError {
            case .rateLimited, .timeout:
                return .transient
            case .guardrailViolation:
                // Both AIKit's PolicyEngine and provider/system guardrails
                // surface this case. Never retriable.
                return .guardrailViolation
            default:
                return .fatal
            }
        case let pccError as PrivateCloudComputeLanguageModel.Error:
            switch pccError {
            case .networkFailure, .serviceUnavailable:
                return .transient
            default:
                return .fatal
            }
        case let classified as any AIKitRetryClassifyingError:
            return classified.aiKitErrorCategory
        default:
            return .fatal
        }
    }
}

/// Optional provider integrations classify their typed errors without making
/// the runtime depend on a concrete provider implementation.
public protocol AIKitRetryClassifyingError: Error {
    var aiKitErrorCategory: ErrorCategory { get }
}
