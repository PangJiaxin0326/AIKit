import Foundation
import FoundationModels
import AIKitCore

/// The four well-defined points at which guardrails run.
///
/// The tool stages (`preToolUse`, `postToolUse`) ride the official
/// `DynamicProfile` hooks inside the session machinery — apply them with
/// `.guardrails(_:)` (see `GuardrailsModifier`). Prompt and response stages
/// use the official prompt/response hooks; the legacy runtime brackets calls.
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
    /// The official multimodal payload; display text is never an image policy.
    public var prompt: Transcript.Prompt?
    /// nil distinguishes unavailable context from an explicitly empty profile.
    public var resolvedContext: GuardrailPromptContext?

    public init(instructions: String, userPrompt: String, toolNames: Set<String>) {
        self.instructions = instructions
        self.userPrompt = userPrompt
        self.toolNames = toolNames
        self.prompt = nil
        self.resolvedContext = GuardrailPromptContext(instructions: instructions, toolNames: toolNames)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(instructions)
        hasher.combine(userPrompt)
        hasher.combine(toolNames)
        hasher.combine(prompt?.id)
        hasher.combine(resolvedContext)
    }

    /// The `prePrompt` payload for a prompt delivered by the official
    /// `onPrompt` hook. The hook's payload is the prompt alone — the
    /// instructions and tool names come from the profile author's immutable
    /// context snapshot (see `GuardrailPromptContext`).
    public init(prompt: Transcript.Prompt, context: GuardrailPromptContext? = nil) {
        self.instructions = context?.instructions ?? ""
        self.toolNames = context?.toolNames ?? []
        self.userPrompt = prompt.segments.compactMap { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            case .attachment: nil
            @unknown default: nil
            }
        }.joined(separator: "\n")
        self.prompt = prompt
        self.resolvedContext = context
    }

}

/// The immutable resolved-context snapshot the prompt-stage payload carries
/// for rails that inspect instructions or tool names. The official `onPrompt`
/// hook delivers only the prompt, so the profile author supplies what the
/// profile already knows about itself when applying `.guardrails(_:)`.
public struct GuardrailPromptContext: Sendable, Hashable {
    public var instructions: String
    public var toolNames: Set<String>

    public init(instructions: String = "", toolNames: Set<String> = []) {
        self.instructions = instructions
        self.toolNames = toolNames
    }
}

/// Stage-specific data handed to a guardrail. The tool stages carry the
/// official transcript shapes the session hooks deliver — including the real
/// call id — not AIKit-local mirrors of them.
public enum GuardrailPayload: Sendable {
    /// The prompt delivered by the official prompt hook, before generation.
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
