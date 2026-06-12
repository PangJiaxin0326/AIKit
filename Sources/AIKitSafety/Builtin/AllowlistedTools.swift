import Foundation

/// Blocks any tool call whose name is not in the resolved context's allowed
/// set. Defense in depth against prompt injection.
public struct AllowlistedTools: Guardrail {
    public let id = "builtin.allowlistedTools"
    public let stages: Set<GuardrailStage> = [.preToolUse]
    private let allowed: Set<String>

    public init(allowed: Set<String>) {
        self.allowed = allowed
    }

    public func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
        guard case .preToolUse(let call) = payload else { return .pass }
        if allowed.contains(call.toolName) {
            return .pass
        }
        return .block(reason: "Tool '\(call.toolName)' is not allowed in this context.")
    }
}
