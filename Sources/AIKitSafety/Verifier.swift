import Foundation
import AIKitCore
import AIKitCapability

/// The four well-defined points at which guardrails run.
public enum Verifier {
    public enum Stage: String, Sendable, Hashable, CaseIterable {
        case prePrompt
        case preToolUse
        case postToolUse
        case finalResult
    }

    public enum Outcome: Sendable, Hashable {
        case pass
        case warn(reason: String)
        case block(reason: String)
    }
}

/// Stage-specific data handed to a guardrail.
public enum GuardrailPayload: Sendable {
    case prePrompt(RenderedPrompt)
    case preToolUse(ToolCall)
    case postToolUse(name: String, output: Data, isError: Bool)
    case finalResult(String)

    public var stage: Verifier.Stage {
        switch self {
        case .prePrompt: return .prePrompt
        case .preToolUse: return .preToolUse
        case .postToolUse: return .postToolUse
        case .finalResult: return .finalResult
        }
    }
}

/// A single safety check bound to one or more stages.
public protocol Guardrail: Sendable {
    var id: String { get }
    var stages: Set<Verifier.Stage> { get }
    func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome
}

/// Thrown when any guardrail blocks. Categorized by the ErrorHandler as
/// `.guardrailViolation` (never retriable).
public struct GuardrailViolation: Error, Sendable, Hashable {
    public let railID: String
    public let stage: Verifier.Stage
    public let reason: String

    public init(railID: String, stage: Verifier.Stage, reason: String) {
        self.railID = railID
        self.stage = stage
        self.reason = reason
    }
}
