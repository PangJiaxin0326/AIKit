import Foundation
import AIKitCore

/// An opaque handle for a single `push`. Popping by token removes exactly the
/// frame that was pushed, so two live views sharing a `ViewContext.ID` (or a
/// re-run SwiftUI task) can no longer pop each other's frame.
public struct ContextToken: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate init(id: UUID) { self.id = id }
}

/// Owns the view-context stack. An actor because views push/pop from
/// concurrent tasks (`.onAppear` / `.onDisappear`).
public actor ContextResolver {
    private struct Frame {
        let token: UUID
        let context: ViewContext
    }

    private var frames: [Frame] = []

    public init() {}

    /// Pushes `context` and returns a token that pops exactly this frame.
    @discardableResult
    public func push(_ context: ViewContext) -> ContextToken {
        let token = UUID()
        frames.append(Frame(token: token, context: context))
        return ContextToken(id: token)
    }

    /// Removes the exact frame created by the matching `push`. Idempotent: a
    /// double pop (e.g. from both `.onDisappear` and task cancellation) is a
    /// no-op the second time.
    public func pop(_ token: ContextToken) {
        frames.removeAll { $0.token == token.id }
    }

    /// The current stack, deepest view last.
    public func current() -> [ViewContext] {
        frames.map(\.context)
    }

    /// Merges the stack into one bundle (root → leaf). System prompt fragments
    /// are concatenated in order; tool names are unioned; later metadata wins.
    public func merged() -> ResolvedContext {
        var fragments: [String] = []
        var tools: Set<String> = []
        var metadata: [String: String] = [:]
        for frame in frames {
            let context = frame.context
            if !context.systemPromptFragment.isEmpty {
                fragments.append(context.systemPromptFragment)
            }
            tools.formUnion(context.toolNames)
            metadata.merge(context.metadata) { _, new in new }
        }
        return ResolvedContext(
            stack: frames.map(\.context.id),
            systemPromptFragment: fragments.joined(separator: "\n\n"),
            toolNames: tools,
            metadata: metadata
        )
    }
}
