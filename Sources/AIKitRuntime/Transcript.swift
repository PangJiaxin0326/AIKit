import Foundation
import AIKitCore
import AIKitCapability

/// One step in the current turn's LLM↔tool ping-pong. Discarded after the turn;
/// the durable record lives in `MemoryStore`.
public enum TranscriptEntry: Sendable, Hashable {
    /// The model's output for an iteration (text and/or tool_use blocks).
    case assistant([ContentBlock])
    /// The result of executing a tool the model requested.
    case toolResult(id: String, name: String, content: String, isError: Bool)
    /// Corrective guidance after a malformed model/tool turn. Sent as a user
    /// message so providers never see an orphan tool result.
    case correctiveGuidance(String)

    /// Converts this entry to the wire `Message` the next prompt will include.
    public var message: Message {
        switch self {
        case .assistant(let blocks):
            return Message(role: .assistant, content: blocks)
        case .toolResult(let id, _, let content, let isError):
            return Message(
                role: .tool,
                content: [.toolResult(toolUseID: id, content: content, isError: isError)]
            )
        case .correctiveGuidance(let content):
            return Message(role: .user, text: content)
        }
    }
}
