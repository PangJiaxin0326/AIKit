import Foundation
import FoundationModels
import AIKitCore

/// Applies a `PolicyEngine`'s guardrails to every stage of a session's turn,
/// the way `SystemLanguageModel.Guardrails` screens the system model:
/// enforcement rides the session machinery itself — the official
/// `DynamicProfile` lifecycle hooks — and a block surfaces as the official
/// `LanguageModelError.guardrailViolation`. No tool wrapping, no per-tool
/// registration: every prompt, tool call, and response the session produces
/// passes the same global policies.
///
/// ```swift
/// let session = LanguageModelSession(profile:
///     LanguageModelSession.Profile {
///         Instructions(instructions)
///         tools
///     }
///     .model(model)
///     .guardrails(engine, activity: sink)
/// )
/// ```
///
/// Stage boundaries, all inside the session:
/// - `prePrompt` runs in `.onPrompt`, before model generation — a block
///   prevents the turn from ever reaching the model. The payload's
///   instructions and tool names come from the optional
///   `GuardrailPromptContext` snapshot (the official hook delivers only the
///   prompt).
/// - `preToolUse` runs in `.onToolCall`, before the tool executes — a block
///   prevents execution and reaches the `respond` caller wrapped in the
///   official `LanguageModelSession.ToolCallError` (match `underlyingError`).
/// - `postToolUse` runs in `.onToolOutput`, on the executed call's official
///   output entry, and propagates raw.
/// - `finalResult` runs in `.onResponse`, on each non-empty response entry's
///   text. A tool-only round trip records an empty response entry, which is
///   skipped — for the classic tool-loop turn the rail evaluates exactly the
///   terminal, user-visible response (cardinality pinned by tests). A model
///   that emits prose alongside its tool calls has that intermediate prose
///   evaluated too, which is the conservative side of the boundary.
///
/// Native stream snapshots are provisional and can precede `onResponse`.
/// Use AIKitConversation.collectResponse or respond for validated delivery.
/// Warnings never enter the transcript: they go to the optional
/// `GuardrailActivitySink` for UI and diagnostics.
public struct GuardrailsModifier: LanguageModelSession.DynamicProfileModifier {
    private let engine: PolicyEngine
    private let promptContext: @Sendable () -> GuardrailPromptContext?
    private let activity: (any GuardrailActivitySink)?

    public init(
        _ engine: PolicyEngine,
        promptContext: GuardrailPromptContext? = nil,
        activity: (any GuardrailActivitySink)? = nil
    ) {
        self.engine = engine
        self.promptContext = { promptContext }
        self.activity = activity
    }

    /// Resolve host context when the prompt hook runs, so dynamic profile
    /// branches can supply their current instruction/tool snapshot.
    public init(
        _ engine: PolicyEngine,
        resolvingContext: @escaping @Sendable () -> GuardrailPromptContext?,
        activity: (any GuardrailActivitySink)? = nil
    ) {
        self.engine = engine
        self.promptContext = resolvingContext
        self.activity = activity
    }

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content
            .onPrompt { [engine, promptContext, activity] prompt in
                let warnings = try await engine.verify(
                    .prePrompt,
                    .prePrompt(RenderedPrompt(prompt: prompt, context: promptContext()))
                )
                for warning in warnings { await activity?.guardrailWarned(warning) }
            }
            .onToolCall { [engine, activity] call in
                let warnings = try await engine.verify(
                    .preToolUse, .preToolUse(call)
                )
                for warning in warnings { await activity?.guardrailWarned(warning) }
            }
            .onToolOutput { [engine, activity] call, output in
                let warnings = try await engine.verify(
                    .postToolUse, .postToolUse(call, output)
                )
                for warning in warnings { await activity?.guardrailWarned(warning) }
            }
            .onResponse { [engine, activity] response in
                // A tool round trip records an empty response entry before
                // the loop continues (pinned by tests); the final-result
                // stage evaluates user-visible text, so empty entries pass.
                let text = response.contentText
                guard !text.isEmpty else { return }
                let warnings = try await engine.verify(
                    .finalResult, .finalResult(text)
                )
                for warning in warnings { await activity?.guardrailWarned(warning) }
            }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Enforces the engine's guardrails at every stage of this session's
    /// turns. See `GuardrailsModifier`.
    public func guardrails(
        _ engine: PolicyEngine,
        promptContext: GuardrailPromptContext? = nil,
        activity: (any GuardrailActivitySink)? = nil
    ) -> some LanguageModelSession.DynamicProfile {
        modifier(GuardrailsModifier(
            engine, promptContext: promptContext, activity: activity
        ))
    }
}

extension LanguageModelSession.DynamicProfile {
    public func guardrails(
        _ engine: PolicyEngine,
        resolvingContext: @escaping @Sendable () -> GuardrailPromptContext?,
        activity: (any GuardrailActivitySink)? = nil
    ) -> some LanguageModelSession.DynamicProfile {
        modifier(GuardrailsModifier(engine, resolvingContext: resolvingContext, activity: activity))
    }
}
