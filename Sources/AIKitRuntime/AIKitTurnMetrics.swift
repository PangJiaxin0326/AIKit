import FoundationModels
import Synchronization

/// Counts completed model rounds independently of transcript retention and
/// rollback. One instance per session. Attach inside throwing response hooks
/// so a later guardrail rejection still counts the generated round.
public final class AIKitTurnMetrics: Sendable {
    private let rounds = Mutex<Int>(0)
    public init() {}
    public var roundTripCount: Int { rounds.withLock { $0 } }
    private func recordResponse() { rounds.withLock { $0 += 1 } }

    public func recording(
        _ profile: consuming some LanguageModelSession.DynamicProfile
    ) -> some LanguageModelSession.DynamicProfile {
        profile.onResponse { [self] _ in recordResponse() }
    }
}

extension LanguageModelSession.DynamicProfile {
    public func measuringRounds(with metrics: AIKitTurnMetrics) -> some LanguageModelSession.DynamicProfile {
        metrics.recording(self)
    }
}
