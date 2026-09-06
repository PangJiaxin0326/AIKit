import Foundation
import FoundationModels

/// Token accounting for one model call, in the shape AIKit persists.
///
/// The official currency is `LanguageModelSession.Usage`; this is its
/// `Codable`/`Hashable` projection for usage records and UI totals.
public struct TokenUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var reasoningOutputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, reasoningOutputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    public init(_ usage: LanguageModelSession.Usage) {
        self.init(
            inputTokens: usage.input.totalTokenCount,
            outputTokens: usage.output.totalTokenCount,
            cachedInputTokens: usage.input.cachedTokenCount,
            reasoningOutputTokens: usage.output.reasoningTokenCount
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedInputTokens, reasoningOutputTokens
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try values.decode(Int.self, forKey: .inputTokens)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        cachedInputTokens = try values.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        reasoningOutputTokens = try values.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
    }

    public static let zero = TokenUsage()
}
