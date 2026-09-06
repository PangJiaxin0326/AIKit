import Foundation
import FoundationModels

/// One shared text projection of the official transcript shapes: text
/// segments verbatim, structured segments as their JSON, anything else by
/// description. Guardrail payloads, activity records, and UI lines all
/// derive display text through these instead of re-walking segments.
extension [Transcript.Segment] {
    public var contentText: String {
        map { segment in
            switch segment {
            case .text(let text):
                text.content
            case .structure(let structured):
                structured.content.jsonString
            default:
                String(describing: segment)
            }
        }.joined(separator: "\n")
    }
}

extension Transcript.Prompt {
    /// The prompt's content as display text.
    public var contentText: String { segments.contentText }
}

extension Transcript.Response {
    /// The response's content as display text.
    public var contentText: String { segments.contentText }
}

extension Transcript.Reasoning {
    /// The reasoning entry's content as display text.
    public var contentText: String { segments.contentText }
}

extension Transcript.ToolOutput {
    /// The official output entry's content as display text.
    public var contentText: String { segments.contentText }
}
