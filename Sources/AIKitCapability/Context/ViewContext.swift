import Foundation
import AIKitCore

/// The per-screen bundle of system prompt fragment and available tool subset.
/// Pushed when a view appears, popped on disappear.
public struct ViewContext: Sendable, Identifiable, Hashable {
    public struct ID: Hashable, Sendable, RawRepresentable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    public let id: ID
    public let displayName: String
    public let systemPromptFragment: String
    public let toolNames: Set<String>
    public let metadata: [String: String]

    public init(
        id: ID,
        displayName: String,
        systemPromptFragment: String = "",
        toolNames: Set<String> = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.systemPromptFragment = systemPromptFragment
        self.toolNames = toolNames
        self.metadata = metadata
    }
}

/// The flattened result of merging the context stack (root → leaf).
public struct ResolvedContext: Sendable, Hashable {
    public let stack: [ViewContext.ID]
    public let systemPromptFragment: String
    public let toolNames: Set<String>
    public let metadata: [String: String]

    public init(
        stack: [ViewContext.ID],
        systemPromptFragment: String,
        toolNames: Set<String>,
        metadata: [String: String]
    ) {
        self.stack = stack
        self.systemPromptFragment = systemPromptFragment
        self.toolNames = toolNames
        self.metadata = metadata
    }

    /// The deepest (most specific) view in the stack, used to attribute events.
    public var leafID: ViewContext.ID {
        stack.last ?? ViewContext.ID("root")
    }

    public static let empty = ResolvedContext(
        stack: [],
        systemPromptFragment: "",
        toolNames: [],
        metadata: [:]
    )
}
