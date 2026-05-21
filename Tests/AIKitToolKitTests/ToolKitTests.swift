import Foundation
import Testing
@testable import AIKitToolKit

private struct EchoTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var echoed: String }

    static let name = "echo"
    static let description = "Echoes input back."
    static let schema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(echoed: "\(context.viewID):\(input.text)")
    }
}

@Suite struct ToolKitRegistryTests {
    @Test func registerAndInvoke() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let context = ToolContext(viewID: "home")
        let input = try JSONEncoder().encode(EchoTool.Input(text: "hi"))
        let outData = try await registry.invoke(
            name: "echo", jsonInput: input, context: context
        )
        let output = try JSONDecoder().decode(EchoTool.Output.self, from: outData)
        #expect(output.echoed == "home:hi")
    }

    @Test func manifestSubsetting() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let subset = await registry.manifest(for: ["echo"])
        #expect(subset.map(\.name) == ["echo"])
        let empty = await registry.manifest(for: [])
        #expect(empty.isEmpty)
    }

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.self) {
            try await registry.invoke(
                name: "nope",
                jsonInput: Data("{}".utf8),
                context: ToolContext(viewID: "v")
            )
        }
    }

    @Test func descriptorPreservesNameAndSchema() {
        let descriptor = EchoTool.descriptor
        #expect(descriptor.name == EchoTool.name)
        #expect(descriptor.description == EchoTool.description)
        #expect(descriptor.inputSchema == EchoTool.schema.json)
    }

    @Test func toolSchemaObjectHasRequiredFields() {
        let schema = ToolSchema.object(
            properties: ["a": .string],
            required: ["a"]
        )
        guard case let .object(fields) = schema.json else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["type"] == .string("object"))
        #expect(fields["required"] == .array([.string("a")]))
    }
}

@Suite struct ToolContextTests {
    @Test func defaultsAreEmpty() {
        let context = ToolContext()
        #expect(context.viewID == "")
        #expect(context.metadata.isEmpty)
    }

    @Test func metadataRoundTrips() {
        let context = ToolContext(viewID: "x", metadata: ["entryID": "1"])
        #expect(context.metadata["entryID"] == "1")
    }
}
