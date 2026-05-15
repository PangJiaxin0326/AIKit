import Foundation
import AIKitCore

/// Built-in tool: mutates a key on the user's profile. Effect supplied by host.
public struct SetProfileTool: Tool {
    public struct Input: Codable, Sendable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public struct Output: Codable, Sendable {
        public var applied: Bool
        public init(applied: Bool) { self.applied = applied }
    }

    public static let name = "setProfile"
    public static let description = "Set a key/value pair on the user's profile."
    public static let schema = ToolSchema.object(
        properties: [
            "key": .string(description: "Profile field name"),
            "value": .string(description: "New value"),
        ],
        required: ["key", "value"]
    )

    private let handler: @Sendable (Input, ToolContext) async throws -> Output

    public init(handler: @escaping @Sendable (Input, ToolContext) async throws -> Output) {
        self.handler = handler
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        try await handler(input, context)
    }
}
