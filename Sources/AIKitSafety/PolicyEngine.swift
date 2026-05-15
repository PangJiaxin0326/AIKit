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

    /// Removes every rail with the given id. Lets a host toggle a rail at
    /// runtime without rebuilding the engine and orchestrator.
    public func unregister(id: String) {
        rails.removeAll { $0.id == id }
    }

    /// Replaces the rail with a matching id (or appends it if absent). The
    /// replacement keeps the original position so stage ordering is stable.
    public func replace(_ rail: any Guardrail) {
        if let index = rails.firstIndex(where: { $0.id == rail.id }) {
            rails[index] = rail
        } else {
            rails.append(rail)
        }
    }

    /// Runs every guardrail bound to `stage`, applying payload rewrites first.
    /// Throws on the first `.block`. Returns the (possibly rewritten) payload
    /// and the warnings raised.
    public func resolve(
        _ stage: Verifier.Stage,
        _ payload: GuardrailPayload
    ) async throws -> (payload: GuardrailPayload, warnings: [String]) {
        var current = payload
        var warnings: [String] = []
        for rail in rails where rail.stages.contains(stage) {
            if let rewritten = await rail.rewrite(current),
               rewritten.stage == stage {
                logger.debug("guardrail \(rail.id, privacy: .public) rewrote payload")
                current = rewritten
            }
            switch await rail.evaluate(current) {
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
        return (current, warnings)
    }

    /// Runs every guardrail bound to `stage`. Throws on the first `.block`.
    /// Returns the warnings raised (if any).
    @discardableResult
    public func verify(
        _ stage: Verifier.Stage,
        _ payload: GuardrailPayload
    ) async throws -> [String] {
        try await resolve(stage, payload).warnings
    }
}
