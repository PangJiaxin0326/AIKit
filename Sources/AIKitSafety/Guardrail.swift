import Foundation
import FoundationModels

/// The four well-defined points at which guardrails run.
///
/// The tool stages (`preToolUse`, `postToolUse`) ride the official
/// `DynamicProfile` hooks inside the session machinery — apply them with
/// `.guardrails(_:)` (see `GuardrailsModifier`). The bracketing stages
/// (`prePrompt`, `finalResult`) run host-side around the session call.
public enum GuardrailStage: String, Sendable, Hashable, CaseIterable {
    case prePrompt
    case preToolUse
    case postToolUse
    case finalResult
}

/// One guardrail's verdict on one payload.
public enum GuardrailOutcome: Sendable, Hashable {
    case pass
    case warn(reason: String)
    case block(reason: String)
}

/// The prompt for one turn as the session will see it: the rendered
/// instructions, the user prompt, and the tool names live for the turn.
public struct RenderedPrompt: Sendable, Hashable {
    public var instructions: String
    public var userPrompt: String
    public var toolNames: Set<String>

    public init(instructions: String, userPrompt: String, toolNames: Set<String>) {
        self.instructions = instructions
        self.userPrompt = userPrompt
        self.toolNames = toolNames
    }
}

/// Stage-specific data handed to a guardrail. The tool stages carry the
/// official transcript shapes the session hooks deliver — including the real
/// call id — not AIKit-local mirrors of them.
public enum GuardrailPayload: Sendable {
    /// The turn's rendered prompt, inspected before the session exists.
    case prePrompt(RenderedPrompt)
    /// A tool call about to execute. Blocking it prevents execution.
    case preToolUse(Transcript.ToolCall)
    /// An executed tool call and its official output entry.
    case postToolUse(Transcript.ToolCall, Transcript.ToolOutput)
    /// The turn's final text.
    case finalResult(String)

    public var stage: GuardrailStage {
        switch self {
        case .prePrompt: return .prePrompt
        case .preToolUse: return .preToolUse
        case .postToolUse: return .postToolUse
        case .finalResult: return .finalResult
        }
    }
}

/// A single safety check bound to one or more stages. Enforcement is
/// error-driven: a `.block` outcome makes `PolicyEngine.verify` throw the
/// official `LanguageModelError.guardrailViolation` — the same error shape
/// `SystemLanguageModel.Guardrails` surfaces — so a blocked turn fails
/// exactly like a system-model guardrail hit.
public protocol Guardrail: Sendable {
    var id: String { get }
    var stages: Set<GuardrailStage> { get }
    func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome
}
