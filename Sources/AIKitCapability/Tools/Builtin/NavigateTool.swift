import Foundation
import FoundationModels
import AIToolKit
import AIKitCore

/// Built-in tool: requests navigation to a named destination. The host app
/// supplies the effect via the injected handler.
public struct NavigateTool: Tool, ToolMetadataProviding {
    @Generable
    public struct Input: Codable, Sendable {
        @Guide(description: "Destination identifier")
        public var destination: String
        public init(destination: String) { self.destination = destination }
    }

    @Generable
    public struct Output: Codable, Sendable {
        public var navigated: Bool
        public init(navigated: Bool) { self.navigated = navigated }
    }

    public static let toolName = "navigate"
    public static let toolDescription = "Navigate the app to a named destination/screen."
    public static let toolAnnotations = ToolAnnotations(
        sideEffect: .localWrite,
        sensitiveOutput: .none
    )
    public static let toolArgumentExamples: [GeneratedContent] = [
        .object(["destination": .string("settings")]),
    ]

    public var name: String { Self.toolName }
    public var description: String { Self.toolDescription }
    public var annotations: ToolAnnotations { Self.toolAnnotations }
    public var argumentExamples: [GeneratedContent] { Self.toolArgumentExamples }

    private let handler: @Sendable (Input) async throws -> Output

    public init(handler: @escaping @Sendable (Input) async throws -> Output) {
        self.handler = handler
    }

    public func call(arguments: Input) async throws -> Output {
        try await handler(arguments)
    }
}
