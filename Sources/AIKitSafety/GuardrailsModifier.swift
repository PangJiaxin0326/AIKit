import Foundation
import FoundationModels

/// Applies a `PolicyEngine`'s guardrails to every tool call a session makes,
/// the way `SystemLanguageModel.Guardrails` screens the system model:
/// enforcement rides the session machinery itself — the official
/// `DynamicProfile` hooks — and a block surfaces as the official
/// `LanguageModelError.guardrailViolation`. No tool wrapping, no per-tool
/// registration: every tool the session can call passes the same global
/// policies.
///
/// ```swift
/// let session = LanguageModelSession(profile:
///     LanguageModelSession.Profile {
///         Instructions(instructions)
///         tools
///     }
///     .model(model)
///     .guardrails(engine)
/// )
/// ```
///
/// `preToolUse` runs in `onToolCall`, before the tool executes — a block
/// prevents execution and reaches the `respond` caller wrapped in the
/// official `LanguageModelSession.ToolCallError` (like any error raised at
/// the tool-call boundary; match `underlyingError`). `postToolUse` runs in
/// `onToolOutput`, on the executed call's official output entry, and
/// propagates raw. The bracketing stages (`prePrompt`, `finalResult`)
/// inspect host-side values that exist outside the session, so hosts run
/// them around the `respond` call (as `Orchestrator` does).
public struct GuardrailsModifier: LanguageModelSession.DynamicProfileModifier {
    private let engine: PolicyEngine

    public init(_ engine: PolicyEngine) {
        self.engine = engine
    }

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content
            .onToolCall { [engine] call in
                try await engine.verify(.preToolUse, .preToolUse(call))
            }
            .onToolOutput { [engine] call, output in
                try await engine.verify(.postToolUse, .postToolUse(call, output))
            }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Enforces the engine's guardrails on every tool call of this session.
    /// See `GuardrailsModifier`.
    public func guardrails(_ engine: PolicyEngine) -> some LanguageModelSession.DynamicProfile {
        modifier(GuardrailsModifier(engine))
    }
}
