import Foundation
import OSLog
import AIKitCore

/// A typed, declarative unit of work the LLM can invoke.
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
public struct ToolContext: Sendable {
    public let viewID: ViewContext.ID
    public let memory: any MemoryStore
    public let logger: Logger

    public init(
        viewID: ViewContext.ID,
        memory: any MemoryStore,
        logger: Logger = AIKitLog.capability
    ) {
        self.viewID = viewID
        self.memory = memory
        self.logger = logger
    }
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
