import Foundation
import FoundationModels
import AIToolKit
import AIKitCore

/// Errors from the runtime's name-based dispatch of parsed provider calls
/// onto the host's official tools.
public enum ToolDispatchError: Error, Sendable {
    /// The model called a tool that is not among the host's tools.
    case unknownTool(String)
    /// The call's arguments failed the tool's strict typed decode.
    case decodingFailed(name: String, detail: String)
}

/// The runtime's name-indexed view over the host's official tools — the same
/// `[any Tool]` currency a `LanguageModelSession` takes. AIKit drives
/// non-Apple providers through its own loop, so the model's calls come back
/// as names + JSON and need a dispatch table; with duplicate names, the
/// first tool wins.
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

    /// Dispatches one parsed provider call: strict typed-argument decode (a
    /// mismatched input fails here, before the tool runs), then the official
    /// `call`, re-encoded so the output can ride the wire back to the model.
    func call(_ call: ToolCall) async throws -> GeneratedContent {
        guard let tool = toolsByName[call.name] else {
            throw ToolDispatchError.unknownTool(call.name)
        }
        return try await Self.invoke(tool, with: call.arguments)
    }

    private static func invoke<T: Tool>(
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
