import Foundation
import OSLog
import AIKitCore

/// Owns the registered guardrails and runs them per stage. Any `.block`
/// outcome throws `GuardrailViolation`; `.warn` outcomes are collected and
/// logged but do not stop the loop.
public actor PolicyEngine {
    private var rails: [any Guardrail]
    private let logger: Logger

    public init(rails: [any Guardrail] = []) {
        self.rails = rails
        self.logger = AIKitLog.safety
    }

    public func register(_ rail: any Guardrail) {
        rails.append(rail)
    }

    /// Runs every guardrail bound to `stage`. Throws on the first `.block`.
    /// Returns the warnings raised (if any).
    @discardableResult
    public func verify(
        _ stage: Verifier.Stage,
        _ payload: GuardrailPayload
    ) async throws -> [String] {
        var warnings: [String] = []
        for rail in rails where rail.stages.contains(stage) {
            switch await rail.evaluate(payload) {
            case .pass:
                continue
            case .warn(let reason):
                warnings.append(reason)
                logger.warning("guardrail \(rail.id, privacy: .public) warned: \(reason, privacy: .public)")
            case .block(let reason):
                logger.error("guardrail \(rail.id, privacy: .public) blocked: \(reason, privacy: .public)")
                throw GuardrailViolation(railID: rail.id, stage: stage, reason: reason)
            }
        }
        return warnings
    }
}
