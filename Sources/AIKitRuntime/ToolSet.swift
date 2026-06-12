import Foundation
import FoundationModels
import AIToolKit

/// A name-indexed view over the host's official tools — the same `[any Tool]`
/// currency a `LanguageModelSession` takes. The session dispatches and
/// executes calls itself; this exists only to resolve a view context's
/// tool-name subset.
struct ToolSet: Sendable {
    private let toolsByName: [String: any Tool]

    init(_ tools: [any Tool]) {
        toolsByName = Dictionary(
            tools.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The named subset, sorted by name (unknown names are dropped).
    func subset(for names: Set<String>) -> [any Tool] {
        names.compactMap { toolsByName[$0] }.sorted { $0.name < $1.name }
    }

    /// Sorted descriptors for the named subset (unknown names are dropped).
    func descriptors(for names: Set<String>) -> [ToolDescriptor] {
        subset(for: names).map(\.descriptor)
    }
}
