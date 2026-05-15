import Foundation

/// A provider-agnostic description of a tool, sent to the LLM so it can decide
/// when and how to call it.
///
/// `inputSchema` is a JSON Schema object describing the tool's input. Capability
/// layer types (e.g. `ToolSchema`) produce these descriptors.
public struct ToolDescriptor: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public var id: String { name }

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
