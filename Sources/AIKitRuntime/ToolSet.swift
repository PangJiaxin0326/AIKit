import Foundation
import FoundationModels
import AIToolKit

/// Thrown when a tool call's arguments fail the tool's strict typed decode.
/// The runtime hands the failure back to the model as the tool's output, so
/// the session can re-issue a corrected call.
public enum ToolDispatchError: Error, Sendable {
    case decodingFailed(name: String, detail: String)
}

/// A name-indexed view over the host's official tools — the same `[any Tool]`
/// currency a `LanguageModelSession` takes. The session dispatches calls
/// itself; this exists to resolve a view context's tool-name subset and to
/// run one strict typed invocation for the guarded wrapper.
struct ToolSet: Sendable {
    private let toolsByName: [String: any Tool]

    init(_ tools: [any Tool]) {
        toolsByName = Dictionary(
            tools.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var names: Set<String> { Set(toolsByName.keys) }

    func contains(_ name: String) -> Bool {
        toolsByName[name] != nil
    }

    /// The named subset, sorted by name (unknown names are dropped).
    func subset(for names: Set<String>) -> [any Tool] {
        names.compactMap { toolsByName[$0] }.sorted { $0.name < $1.name }
    }

    /// Sorted descriptors for the named subset (unknown names are dropped).
    func descriptors(for names: Set<String>) -> [ToolDescriptor] {
        subset(for: names).map(\.descriptor)
    }

    /// One strict typed invocation: decode the session's JSON arguments into
    /// the tool's official `Arguments` (a mismatched input fails here, before
    /// the tool runs), run the official `call`, and re-encode the output for
    /// the wire.
    static func invoke(
        _ tool: any Tool,
        with input: GeneratedContent
    ) async throws -> GeneratedContent {
        try await invokeTyped(tool, with: input)
    }

    private static func invokeTyped<T: Tool>(
        _ tool: T,
        with input: GeneratedContent
    ) async throws -> GeneratedContent {
        let arguments: T.Arguments
        do {
            arguments = try T.Arguments(input)
        } catch {
            throw ToolDispatchError.decodingFailed(
                name: tool.name,
                detail: String(describing: error)
            )
        }
        let output = try await tool.call(arguments: arguments)
        guard let convertible = output as? any ConvertibleToGeneratedContent else {
            throw GenericToolError(message: """
                Output of tool \(tool.name) does not convert to \
                GeneratedContent; AIKit tools need structured (Generable) \
                outputs.
                """)
        }
        return convertible.generatedContent
    }
}
