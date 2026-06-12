import Foundation
import FoundationModels

/// Token accounting for one model call, in the shape AIKit persists.
///
/// The official currency is `LanguageModelSession.Usage`; this is its
/// `Codable`/`Hashable` projection for usage records and UI totals.
public struct TokenUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public init(_ usage: LanguageModelSession.Usage) {
        self.init(
            inputTokens: usage.input.totalTokenCount,
            outputTokens: usage.output.totalTokenCount
        )
    }

    public static let zero = TokenUsage()
}
