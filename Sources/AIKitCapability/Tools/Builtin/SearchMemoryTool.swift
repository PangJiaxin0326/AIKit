import Foundation
import FoundationModels
import AIToolKit

/// Built-in tool: searches the durable memory log. The memory store is
/// injected at init time — the tool standard's `ToolContext` deliberately does
/// not carry a memory handle so AIToolKit can stand alone for non-Capability
/// packages.
public struct SearchMemoryTool: Tool, ToolMetadataProviding {
    @Generable
    public struct Input: Codable, Sendable {
        @Guide(description: "Keyword query")
        public var query: String
        public var limit: Int?
        public init(query: String, limit: Int? = nil) {
            self.query = query
            self.limit = limit
        }
    }

    @Generable
    public struct Hit: Codable, Sendable {
        public var kind: String
        public var timestamp: Double
        public var text: String

        public init(kind: String, timestamp: Double, text: String) {
            self.kind = kind
            self.timestamp = timestamp
            self.text = text
        }
    }

    @Generable
    public struct Output: Codable, Sendable {
        public var hits: [Hit]
        public init(hits: [Hit]) { self.hits = hits }
    }

    public static let toolName = "searchMemory"
    public static let toolDescription = "Search the user's interaction history by keyword."
    public static let toolAnnotations = ToolAnnotations(
        isReadOnly: true,
        isIdempotent: true,
        sideEffect: .none,
        sensitiveOutput: .privateContent,
        cachePolicy: .memory
    )
    public static let toolArgumentExamples: [GeneratedContent] = [
        .object(["query": .string("passport renewal"), "limit": .int(5)]),
    ]

    public var name: String { Self.toolName }
    public var description: String { Self.toolDescription }
    public var annotations: ToolAnnotations { Self.toolAnnotations }
    public var argumentExamples: [GeneratedContent] { Self.toolArgumentExamples }

    private let memory: any MemoryStore

    public init(memory: any MemoryStore) {
        self.memory = memory
    }

    public func call(arguments input: Input) async throws -> Output {
        let events = try await memory.search(
            query: input.query,
            limit: input.limit ?? 10
        )
        return Output(hits: events.map {
            Hit(
                kind: $0.kind.rawValue,
                timestamp: $0.timestamp.timeIntervalSince1970,
                text: $0.payloadText
            )
        })
    }
}
