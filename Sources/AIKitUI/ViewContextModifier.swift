import SwiftUI
import AIKitCapability

/// Environment slot carrying the app's `ContextResolver` so `.aiContext`
/// modifiers can push/pop without manual plumbing.
private struct ContextResolverKey: EnvironmentKey {
    static let defaultValue = ContextResolver()
}

public extension EnvironmentValues {
    var aiContextResolver: ContextResolver {
        get { self[ContextResolverKey.self] }
        set { self[ContextResolverKey.self] = newValue }
    }
}

private struct AIContextModifier: ViewModifier {
    @Environment(\.aiContextResolver) private var resolver
    let context: ViewContext

    func body(content: Content) -> some View {
        content
            .task(id: context.id) {
                await resolver.push(context)
            }
            .onDisappear {
                let resolver = resolver
                let id = context.id
                Task { await resolver.pop(id) }
            }
    }
}

public extension View {
    /// Pushes `context` onto the shared resolver while this view is on screen,
    /// popping it on disappear.
    func aiContext(_ context: ViewContext) -> some View {
        modifier(AIContextModifier(context: context))
    }

    /// Injects the resolver the orchestrator uses, so `.aiContext` works.
    func aiContextResolver(_ resolver: ContextResolver) -> some View {
        environment(\.aiContextResolver, resolver)
    }
}
