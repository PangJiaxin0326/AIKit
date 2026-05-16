import Foundation

/// A fully `Sendable`, `Codable` representation of arbitrary JSON.
///
/// Used for tool input schemas, tool inputs, and opaque payloads where a
/// concrete `Codable` type is not known at compile time.
///
/// `int` exists because JSON has no integer/float distinction but several
/// backends do: Ollama / llama.cpp / vLLM reject a float where they expect an
/// integer (`num_ctx`, `seed`, `top_k`, `num_predict`). Construct `.int` (or
/// use an integer literal) for those `extraBody` knobs so the wire encoder
/// emits `4096`, not `4096.0`. Decoding never yields `.int` — every JSON
/// number decodes as `.number(Double)` so round-tripping stays lossless and
/// equality stays predictable; `.int` is purely an output-fidelity affordance.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Decodes raw JSON `Data` into a `JSONValue`.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encodes this value to JSON `Data`.
    public func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The integer value, accepting a whole-number `.number` too (decoded JSON
    /// numbers are always `.number`, so callers that mean "an integer" still
    /// resolve `4096` or `4096.0`).
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .number(let value) where value.rounded() == value:
            return Int(value)
        default:
            return nil
        }
    }

    /// Recursively collects every string scalar reachable from this value.
    public var allStrings: [String] {
        switch self {
        case .string(let value): return [value]
        case .array(let values): return values.flatMap(\.allStrings)
        case .object(let object): return object.values.flatMap(\.allStrings)
        case .null, .bool, .int, .number: return []
        }
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
