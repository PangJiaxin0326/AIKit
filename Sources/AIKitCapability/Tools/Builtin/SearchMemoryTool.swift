import Foundation
import AIToolKit

/// Built-in tool: searches the durable memory log. The memory store is
/// injected at init time — the tool standard's `ToolContext` deliberately does
/// not carry a memory handle so AIToolKit can stand alone for non-Capability
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
    public static let inputSchema = ToolSchema.object(
        properties: [
            "query": .string(description: "Keyword query"),
            "limit": .integer,
        ],
        required: ["query"]
    )
    public static let outputSchema = ToolSchema.strictObject(
        properties: [
            "hits": .array(of: .strictObject(
                properties: [
                    "kind": .string,
                    "timestamp": .number,
                    "text": .string,
                ],
                required: ["kind", "timestamp", "text"]
            )),
        ],
        required: ["hits"]
    )
    public static let annotations = ToolAnnotations(
        isReadOnly: true,
        isIdempotent: true,
        sideEffect: .none,
        sensitiveOutput: .privateContent,
        cachePolicy: .memory
    )
    public static let inputExamples: [JSONValue] = [
        .object(["query": .string("passport renewal"), "limit": .int(5)]),
    ]

    private let memory: any MemoryStore

    public init(memory: any MemoryStore) {
        self.memory = memory
    }

    public func call(_ input: Input, in context: ToolContext) async throws -> Output {
        let events = try await memory.search(
            query: input.query,
            limit: input.limit ?? 10
        )
        return Output(hits: events.map {
            Hit(kind: $0.kind.rawValue, timestamp: $0.timestamp, text: $0.payloadText)
        })
    }
}
