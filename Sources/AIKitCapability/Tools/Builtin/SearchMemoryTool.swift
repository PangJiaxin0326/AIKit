import Foundation
import AIKitToolKit

/// Built-in tool: searches the durable memory log. The memory store is
/// injected at init time — the tool standard's `ToolContext` deliberately does
/// not carry a memory handle so AIKitToolKit can stand alone for non-Capability
/// packages.
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

    private let memory: any MemoryStore

    public init(memory: any MemoryStore) {
        self.memory = memory
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let events = try await memory.search(
            query: input.query,
            limit: input.limit ?? 10
        )
        return Output(hits: events.map {
            Hit(kind: $0.kind.rawValue, timestamp: $0.timestamp, text: $0.payloadText)
        })
    }
}
