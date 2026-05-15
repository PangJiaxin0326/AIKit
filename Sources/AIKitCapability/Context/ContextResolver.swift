import Foundation
import AIKitCore

/// Owns the view-context stack. An actor because views push/pop from
/// concurrent tasks (`.onAppear` / `.onDisappear`).
public actor ContextResolver {
    private var stack: [ViewContext] = []

    public init() {}

    public func push(_ context: ViewContext) {
        stack.append(context)
    }

    /// Removes the most recent occurrence of the given view id.
    public func pop(_ id: ViewContext.ID) {
        if let index = stack.lastIndex(where: { $0.id == id }) {
            stack.remove(at: index)
        }
    }

    /// The current stack, deepest view last.
    public func current() -> [ViewContext] {
        stack
    }

    /// Merges the stack into one bundle (root → leaf). System prompt fragments
    /// are concatenated in order; tool names are unioned; later metadata wins.
    public func merged() -> ResolvedContext {
        var fragments: [String] = []
        var tools: Set<String> = []
        var metadata: [String: String] = [:]
        for context in stack {
            if !context.systemPromptFragment.isEmpty {
                fragments.append(context.systemPromptFragment)
            }
            tools.formUnion(context.toolNames)
            metadata.merge(context.metadata) { _, new in new }
        }
        return ResolvedContext(
            stack: stack.map(\.id),
            systemPromptFragment: fragments.joined(separator: "\n\n"),
            toolNames: tools,
            metadata: metadata
        )
    }
}
