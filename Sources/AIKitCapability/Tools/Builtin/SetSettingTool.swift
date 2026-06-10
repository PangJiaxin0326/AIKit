import Foundation
import FoundationModels
import AIToolKit
import AIKitCore

/// Built-in tool: mutates an app setting. Effect supplied by host.
public struct SetSettingTool: Tool {
    @Generable
    public struct Input: Codable, Sendable {
        @Guide(description: "Setting key")
        public var key: String
        @Guide(description: "New value")
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    @Generable
    public struct Output: Codable, Sendable {
        public var applied: Bool
        public init(applied: Bool) { self.applied = applied }
    }

    public static let toolName = "setSetting"
    public static let toolDescription = "Set an application setting key to a value, e.g. key \"notifications\" value \"enabled\"."

    public var name: String { Self.toolName }
    public var description: String { Self.toolDescription }

    private let handler: @Sendable (Input) async throws -> Output

    public init(handler: @escaping @Sendable (Input) async throws -> Output) {
        self.handler = handler
    }

    public func call(arguments: Input) async throws -> Output {
        try await handler(arguments)
    }
}
