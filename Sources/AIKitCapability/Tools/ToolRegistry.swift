import Foundation
import AIKitCore

/// Process-wide tool registry. Allows per-view subsetting via `ViewContext`.
public actor ToolRegistry {
    public static let shared = ToolRegistry()

    private struct Entry {
        let descriptor: ToolDescriptor
        let invoke: @Sendable (Data, ToolContext) async throws -> Data
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register<T: Tool>(_ tool: T) {
        let descriptor = T.descriptor
        let name = T.name
        entries[name] = Entry(descriptor: descriptor) { data, context in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let input: T.Input
            do {
                input = try decoder.decode(T.Input.self, from: data)
            } catch {
                throw ToolRegistryError.decodingFailed(
                    name: name,
                    detail: String(describing: error)
                )
            }
            let output = try await tool.invoke(input, in: context)
            do {
                return try encoder.encode(output)
            } catch {
                throw ToolRegistryError.encodingFailed(
                    name: name,
                    detail: String(describing: error)
                )
            }
        }
    }

    public func unregister(name: String) {
        entries.removeValue(forKey: name)
    }

    public func registeredNames() -> Set<String> {
        Set(entries.keys)
    }

    /// Returns the schema bundle for the given subset (used by PromptBuilder).
    /// An empty `names` set returns all registered tools.
    public func manifest(for names: Set<String>) -> [ToolDescriptor] {
        let selected = names.isEmpty
            ? Array(entries.values)
            : names.compactMap { entries[$0] }
        return selected.map(\.descriptor).sorted { $0.name < $1.name }
    }

    /// Dispatches an invocation by name; decodes input, encodes output.
    public func invoke(
        name: String,
        jsonInput: Data,
        context: ToolContext
    ) async throws -> Data {
        guard let entry = entries[name] else {
            throw ToolRegistryError.notRegistered(name)
        }
        return try await entry.invoke(jsonInput, context)
    }
}
