import Foundation
import AIKitCore

/// Flags user instructions containing common jailbreak phrases. Emits `.warn`
/// (not `.block`) by default so the host can decide how to react.
public struct InjectionSniffer: Guardrail {
    public let id = "builtin.injectionSniffer"
    public let stages: Set<Verifier.Stage> = [.prePrompt]
    private let blocking: Bool

    private static let phrases = [
        "ignore previous instructions",
        "ignore all previous",
        "disregard the above",
        "you are now",
        "developer mode",
        "jailbreak",
        "system prompt",
        "reveal your instructions",
    ]

    /// - Parameter blocking: if true, matches `.block` instead of `.warn`.
    public init(blocking: Bool = false) {
        self.blocking = blocking
    }

    public func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        guard case .prePrompt(let prompt) = payload else { return .pass }
        let haystack = (prompt.latestUserText ?? "").lowercased()
        guard let hit = Self.phrases.first(where: haystack.contains) else {
            return .pass
        }
        let reason = "User instruction contains a possible injection phrase: '\(hit)'."
        return blocking ? .block(reason: reason) : .warn(reason: reason)
    }
}
