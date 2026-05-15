import Foundation

/// Blocks final responses over a configured character cap.
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
