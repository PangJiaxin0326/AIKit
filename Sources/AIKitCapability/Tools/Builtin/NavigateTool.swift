import Foundation
import AIKitCore

/// Built-in tool: requests navigation to a named destination. The host app
/// supplies the effect via the injected handler.
public struct NavigateTool: Tool {
    public struct Input: Codable, Sendable {
        public var destination: String
        public init(destination: String) { self.destination = destination }
    }

    public struct Output: Codable, Sendable {
        public var navigated: Bool
        public init(navigated: Bool) { self.navigated = navigated }
    }

    public static let name = "navigate"
    public static let description = "Navigate the app to a named destination/screen."
    public static let schema = ToolSchema.object(
        properties: ["destination": .string(description: "Destination identifier")],
        required: ["destination"]
    )

    private let handler: @Sendable (Input, ToolContext) async throws -> Output

    public init(handler: @escaping @Sendable (Input, ToolContext) async throws -> Output) {
        self.handler = handler
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        try await handler(input, context)
    }
}
