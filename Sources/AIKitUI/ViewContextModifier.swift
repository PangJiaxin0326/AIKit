import SwiftUI
import AIKitCapability

/// Environment slot carrying the app's `ContextResolver` so `.aiContext`
/// modifiers can push/pop without manual plumbing.
private enum AIContextResolverDefault {
    static let shared = ContextResolver()
}

public extension EnvironmentValues {
    @Entry var aiContextResolver = AIContextResolverDefault.shared
}

struct AIKitContextLifecycleModifier: ViewModifier {
    @Environment(\.aiContextResolver) private var resolver
    let context: ViewContext?

    func body(content: Content) -> some View {
        content
            // `.task(id:)` runs on appear and is cancelled on disappear or
            // when the keyed value changes. Keying on the whole `context`
            // (not just `context.id`) means mutating `systemPromptFragment`
            // or `toolNames` while keeping the same id re-pushes a fresh
            // frame instead of stranding the stale one. Pushing here and
            // popping the exact token when the task ends keeps push/pop
            // balanced even with two live views sharing an id.
            .task(id: context) {
                guard let context else { return }
                let token = await resolver.push(context)
                do {
                    // Park until the task is cancelled (view disappeared or
                    // context changed); `Task.sleep` throws `CancellationError`
                    // immediately on cancel regardless of the duration. The
                    // bounded interval just avoids any deadline overflow.
                    while true {
                        try await Task.sleep(for: .seconds(3600))
                    }
                } catch {
                    await resolver.pop(token)
                }
            }
    }
}

public extension View {
    /// Pushes `context` onto the shared resolver while this view is on screen,
    /// popping it on disappear.
    func aiContext(_ context: ViewContext) -> some View {
        modifier(AIKitContextLifecycleModifier(context: context))
    }

    /// Injects the resolver the orchestrator uses, so `.aiContext` works.
    func aiContextResolver(_ resolver: ContextResolver) -> some View {
        environment(\.aiContextResolver, resolver)
    }
}
