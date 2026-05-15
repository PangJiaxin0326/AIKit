import Foundation

/// Blocks final responses longer than a configured number of **characters**
/// (not tokens — this is a cheap guard against runaway output, not a token
/// budget).
public struct OutputLengthCap: Guardrail {
    public let id = "builtin.outputLengthCap"
    public let stages: Set<Verifier.Stage> = [.finalResult]
    private let maxCharacters: Int

    public init(maxCharacters: Int = 8_000) {
        self.maxCharacters = maxCharacters
    }

    public func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        guard case .finalResult(let text) = payload else { return .pass }
        if text.count > maxCharacters {
            return .block(
                reason: "Final response is \(text.count) characters, over the \(maxCharacters) cap."
            )
        }
        return .pass
    }
}
