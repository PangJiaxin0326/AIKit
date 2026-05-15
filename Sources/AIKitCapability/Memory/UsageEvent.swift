import Foundation
import AIKitCore

/// A single durable record of a user→agent interaction.
public struct UsageEvent: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let viewID: ViewContext.ID
    public let kind: Kind
    public let payload: Data

    public enum Kind: String, Codable, Sendable {
        case userInstruction
        case toolInvoked
        case toolResult
        case llmResponse
        case error
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        viewID: ViewContext.ID,
        kind: Kind,
        payload: Data
    ) {
        self.id = id
        self.timestamp = timestamp
        self.viewID = viewID
        self.kind = kind
        self.payload = payload
    }

    /// Convenience constructor for a UTF-8 text payload.
    public init(
        viewID: ViewContext.ID,
        kind: Kind,
        text: String,
        timestamp: Date = Date()
    ) {
        self.init(
            id: UUID(),
            timestamp: timestamp,
            viewID: viewID,
            kind: kind,
            payload: Data(text.utf8)
        )
    }

    public var payloadText: String {
        String(decoding: payload, as: UTF8.self)
    }
}
