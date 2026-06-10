import Foundation
import FoundationModels

/// A parsed request from the model to call a tool, as it arrives on a
/// provider wire (a native `tool_use` block, or one recovered from text).
///
/// This is AIKit's wire model: AIKit drives non-Apple providers through its
/// own loop, so it parses calls itself instead of letting a
/// `LanguageModelSession` do it. Tools themselves stay official
/// `FoundationModels.Tool` values; this type never outlives the dispatch
/// boundary.
public struct ToolCall: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var arguments: GeneratedContent

    public init(id: String? = nil, name: String, arguments: GeneratedContent) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
