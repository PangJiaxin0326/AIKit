import Foundation
import FoundationModels
import OSLog
import AIKitCore

/// Owns the registered guardrails and runs them per stage. Enforcement is
/// error-driven, after `SystemLanguageModel.Guardrails`: any `.block` outcome
/// throws the official `LanguageModelError.guardrailViolation`; `.warn`
/// outcomes are collected and logged but do not stop the loop.
///
/// Attach the engine to a session with the `.guardrails(_:)` profile
/// modifier so the tool stages run inside the session machinery.
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

    /// Runs every guardrail bound to `stage`. The first `.block` throws the
    /// official `LanguageModelError.guardrailViolation`, carrying the rail
    /// id, stage, and reason in its `metadata`. Returns the warnings raised
    /// (if any).
    @discardableResult
    public func verify(
        _ stage: GuardrailStage,
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
                throw LanguageModelError.guardrailViolation(.init(
                    debugDescription: "Blocked by \(rail.id): \(reason)",
                    metadata: [
                        "railID": rail.id,
                        "stage": stage.rawValue,
                        "reason": reason,
                    ]
                ))
            }
        }
        return warnings
    }
}
