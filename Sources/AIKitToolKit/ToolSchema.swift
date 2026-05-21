import Foundation

/// A small JSON Schema builder for describing tool inputs.
public struct ToolSchema: Sendable, Hashable {
    public var json: JSONValue

    public init(json: JSONValue) {
        self.json = json
    }

    public static let string = ToolSchema(json: .object(["type": .string("string")]))
    public static let number = ToolSchema(json: .object(["type": .string("number")]))
    public static let integer = ToolSchema(json: .object(["type": .string("integer")]))
    public static let boolean = ToolSchema(json: .object(["type": .string("boolean")]))

    public static func string(description: String) -> ToolSchema {
        ToolSchema(json: .object([
            "type": .string("string"),
            "description": .string(description),
        ]))
    }

    public static func array(of element: ToolSchema) -> ToolSchema {
        ToolSchema(json: .object([
            "type": .string("array"),
            "items": element.json,
        ]))
    }

    public static func object(
        properties: [String: ToolSchema],
        required: [String] = []
    ) -> ToolSchema {
        let props = properties.mapValues(\.json)
        return ToolSchema(json: .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map(JSONValue.string)),
        ]))
    }
}
