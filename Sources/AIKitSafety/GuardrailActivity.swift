import Foundation

/// One rail's `.warn` outcome, with enough identity for UI and diagnostics.
public struct GuardrailWarning: Sendable, Hashable {
    public let railID: String
    public let stage: GuardrailStage
    public let reason: String

    public init(railID: String, stage: GuardrailStage, reason: String) {
        self.railID = railID
        self.stage = stage
        self.reason = reason
    }
}

/// Where warnings go when the rails run inside the session machinery.
///
/// A profile lifecycle hook can throw to block, but has no return channel
/// for non-blocking findings — and warnings do not belong in the transcript.
/// Hosts hand a sink to `.guardrails(_:activity:)`; UI and diagnostics
/// observe it. Blocks keep throwing the official
/// `LanguageModelError.guardrailViolation`.
public protocol GuardrailActivitySink: Sendable {
    func guardrailWarned(_ warning: GuardrailWarning) async
}
