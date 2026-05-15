import Foundation
import AIKitCapability

/// Blocks any tool call whose name is not in the resolved context's allowed
/// set. Defense in depth against prompt injection.
public struct AllowlistedTools: Guardrail {
    public let id = "builtin.allowlistedTools"
    public let stages: Set<Verifier.Stage> = [.preToolUse]
    private let allowed: Set<String>

    public init(allowed: Set<String>) {
        self.allowed = allowed
    }

    public func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        guard case .preToolUse(let call) = payload else { return .pass }
        if allowed.isEmpty || allowed.contains(call.name) {
            return .pass
        }
        return .block(reason: "Tool '\(call.name)' is not allowed in this context.")
    }
}
