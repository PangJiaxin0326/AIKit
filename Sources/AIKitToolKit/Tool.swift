import Foundation
import OSLog

/// A typed, declarative unit of work the LLM can invoke.
///
/// AIKitToolKit defines the standard so any Swift package can ship `Tool`s
/// without depending on the rest of AIKit. The hosting app wires them into an
/// `AIKitCapability.ToolRegistry` and runs them through `AIKitRuntime`.
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var schema: ToolSchema { get }

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output
}

extension Tool {
    /// The provider-facing descriptor derived from the tool's static metadata.
    public static var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: schema.json
        )
    }
}

/// Ambient state handed to a tool during invocation.
///
/// Kept deliberately small so AIKitToolKit can stand alone: the view id is a
/// bare `String` (the host runtime supplies the leaf view's id) and richer
/// dependencies — memory stores, persistence handles, network clients — are
/// held on the conforming tool itself, injected at construction.
public struct ToolContext: Sendable {
    /// The leaf view's id (`ViewContext.ID.rawValue` when AIKitCapability is
    /// driving). Empty when no view is in scope.
    public let viewID: String
    /// Free-form context the host wants the tool to see (e.g. the foreground
    /// entry id). Sub-string lookup only — keep keys stable.
    public let metadata: [String: String]
    public let logger: Logger

    public init(
        viewID: String = "",
        metadata: [String: String] = [:],
        logger: Logger = Self.defaultLogger
    ) {
        self.viewID = viewID
        self.metadata = metadata
        self.logger = logger
    }

    public static let defaultLogger = Logger(
        subsystem: "com.aikit.toolkit", category: "tool"
    )
}

/// Errors thrown by tools carry retriability so the ErrorHandler can decide
/// whether to loop back.
public protocol ToolError: Error, Sendable {
    var isRetriable: Bool { get }
}

/// A general-purpose `ToolError` for simple cases.
public struct GenericToolError: ToolError {
    public let message: String
    public let isRetriable: Bool

    public init(message: String, isRetriable: Bool = false) {
        self.message = message
        self.isRetriable = isRetriable
    }
}

/// A parsed request from the model to invoke a tool.
public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String?
    public var name: String
    public var input: JSONValue

    public init(id: String? = nil, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Errors from the registry dispatch path itself.
public enum ToolRegistryError: Error, Sendable {
    case notRegistered(String)
    case decodingFailed(name: String, detail: String)
    case encodingFailed(name: String, detail: String)
}
