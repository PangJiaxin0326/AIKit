import Foundation
import AIKitCore

/// Built-in tool: searches the durable memory log. Reads from the
/// `ToolContext.memory` store, so it needs no host handler.
public struct SearchMemoryTool: Tool {
    public struct Input: Codable, Sendable {
        public var query: String
        public var limit: Int?
        public init(query: String, limit: Int? = nil) {
            self.query = query
            self.limit = limit
        }
    }

    public struct Hit: Codable, Sendable {
        public var kind: String
        public var timestamp: Date
        public var text: String
    }

    public struct Output: Codable, Sendable {
        public var hits: [Hit]
        public init(hits: [Hit]) { self.hits = hits }
    }

    public static let name = "searchMemory"
    public static let description = "Search the user's interaction history by keyword."
    public static let schema = ToolSchema.object(
        properties: [
            "query": .string(description: "Keyword query"),
            "limit": .integer,
        ],
        required: ["query"]
    )

    public init() {}

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let events = try await context.memory.search(
            query: input.query,
            limit: input.limit ?? 10
        )
        return Output(hits: events.map {
            Hit(kind: $0.kind.rawValue, timestamp: $0.timestamp, text: $0.payloadText)
        })
    }
}
