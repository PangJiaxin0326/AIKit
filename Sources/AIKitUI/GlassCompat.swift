import SwiftUI

// Liquid Glass compatibility shims.
//
// The Liquid Glass APIs introduced in 2025 — `glassEffect(_:in:)`,
// `GlassEffectContainer`, and `.buttonStyle(.glass)` — are available on iOS and
// macOS but are *unavailable on visionOS*, which ships its own glass system
// (`glassBackgroundEffect`). AIKit declares visionOS in its supported platforms,
// so AIKitUI must compile there too. These helpers forward to the real Glass
// APIs everywhere they exist and fall back to the closest native treatment on
// visionOS, keeping the iOS/macOS appearance byte-identical (the `#else` branch
// is the original call) while letting the package build for visionOS.

extension View {
    /// `glassEffect(_:in:)` where it exists; a translucent system material on
    /// visionOS. `tint`/`interactive` mirror the Glass builder used at the call
    /// sites so the non-visionOS path is unchanged.
    func aiKitGlassEffect<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        #if os(visionOS)
        // visionOS has no `glassEffect`; a thin material reads as the same
        // translucent chip and keeps the tint/stroke overlays at the call site
        // legible. Apply the tint as a faint fill so the accent still carries.
        return self.background {
            shape
                .fill(.thinMaterial)
                .overlay { shape.fill((tint ?? .clear).opacity(0.5)) }
        }
        #else
        var glass: Glass = .regular
        if interactive { glass = glass.interactive() }
        if let tint { glass = glass.tint(tint) }
        return self.glassEffect(glass, in: shape)
        #endif
    }

    /// `.buttonStyle(.glass)` where it exists; `.bordered` on visionOS.
    @ViewBuilder
    func aiKitGlassButtonStyle() -> some View {
        #if os(visionOS)
        self.buttonStyle(.bordered)
        #else
        self.buttonStyle(.glass)
        #endif
    }
}

/// `GlassEffectContainer` where it exists; a transparent passthrough on visionOS
/// (the container only coordinates glass merging, which visionOS doesn't have).
struct AIKitGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(visionOS)
        content()
        #else
        GlassEffectContainer(spacing: spacing) { content() }
        #endif
    }
}
