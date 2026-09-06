import Foundation
import FoundationModels
import AIKitCapability

/// Ends the turn as a refusal the moment the model calls the built-in
/// `reportFailure` escape hatch — before the tool executes. Apply it to any
/// profile whose tool set includes `ReportFailureTool`:
///
/// ```swift
/// LanguageModelSession.Profile {
///     Instructions(instructions)
///     tools + [ReportFailureTool()]
/// }
/// .model(model)
/// .refusalEscapeHatch()   // BEFORE .guardrails: hooks run in application
/// .guardrails(engine)     // order, so the hatch outranks a strict
///                         // allowlist that (correctly) omits
///                         // reportFailure (pinned by tests)
/// ```
///
/// The refusal surfaces from `respond` as `TurnRefusal` wrapped in the
/// official `LanguageModelSession.ToolCallError`. `AIKitConversation`
/// unwraps it, records the turn as `.refused`, never retries it, and
/// rethrows it raw.
public struct RefusalEscapeHatchModifier: LanguageModelSession.DynamicProfileModifier {
    public init() {}

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content.onToolCall { call in
            if call.toolName == ReportFailureTool.toolName {
                throw TurnRefusal(reason: ReportFailureTool.reason(from: call.arguments))
            }
        }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Turns a `reportFailure` tool call into a `TurnRefusal` before the
    /// tool executes. See `RefusalEscapeHatchModifier`.
    public func refusalEscapeHatch() -> some LanguageModelSession.DynamicProfile {
        modifier(RefusalEscapeHatchModifier())
    }
}
