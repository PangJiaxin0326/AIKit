import Foundation
import FoundationModels
import SwiftUI
import Observation
import AIToolKit
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import UICollection
#endif
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety
import MultiModalKit

func aiKitText(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: .module)
}

/// One proportion scale shared across AIKit's UI — the configuration
/// dashboard and the floating chatbot — so every surface reads as a single,
/// deliberately measured system rather than a stack of defaults.
///
/// Spacing follows one quiet rhythm (8 · 12 · 16 · 20 · 24); nested corner
/// radii stay roughly concentric — an inset control's curve echoes the card
/// that holds it — so the whole interface reads as a single hand.
enum AIKitMetrics {
    /// Gap between the stacked configuration surfaces.
    static let sectionSpacing: CGFloat = 18
    /// Gap between rows within a surface.
    static let rowSpacing: CGFloat = 14
    /// Inset inside each surface.
    static let cardPadding: CGFloat = 18
    /// Margin around the whole dashboard column.
    static let pagePadding: CGFloat = 28
    /// Section surfaces and their icon badges share one measured curve.
    static let cardRadius: CGFloat = 18
    static let fieldRadius: CGFloat = 12
    /// One shared width for every inline value field, so the trailing boxes
    /// align into a single column and always fit beside their row label.
    static let fieldWidth: CGFloat = 160
    static let badgeRadius: CGFloat = 9
    static let badgeSize: CGFloat = 32
    /// Comfortable reading measure; the column centers within wider windows.
    static let contentWidth: CGFloat = 760
    static var textFieldRowSpacer: CGFloat {
        #if os(macOS)
        32
        #elseif os(visionOS)
        24
        #else
        16
        #endif
    }
    static var textFieldStackSpacing: CGFloat {
        #if os(macOS)
        6
        #else
        8
        #endif
    }

    /// Floating chatbot overlay — pet button, glass capsule, detail panel.
    static let petDiameter: CGFloat = 58
    static let edgeInset: CGFloat = 16
    static let panelRadius: CGFloat = 22
    static let panelWidth: CGFloat = 380
    /// Inset inside the floating detail panel.
    static let panelPadding: CGFloat = 20
    /// Curve for soft cards floating inside or beside the panel — the
    /// failure-reason note — sized to sit concentrically within the panel.
    static let controlRadius: CGFloat = 14
}

/// Current UI context passed into custom AIKit overlay and tab-FAB content.
public struct AIKitOverlayContext: Sendable, Hashable {
    /// The deepest visible view context, either from the orchestrator snapshot
    /// or provided by a tab integration.
    public let currentViewContext: ViewContext?
    public let resolvedContext: ResolvedContext
    public let snapshot: OrchestratorSnapshot?

    public init(
        currentViewContext: ViewContext? = nil,
        resolvedContext: ResolvedContext = .empty,
        snapshot: OrchestratorSnapshot? = nil
    ) {
        self.currentViewContext = currentViewContext ?? snapshot?.contexts.last
        self.resolvedContext = snapshot?.resolvedContext ?? resolvedContext
        self.snapshot = snapshot
    }
}

extension OrchestratorActivity {
    var aiKitLocalizedStatusText: String {
        if isBusy {
            switch phase {
            case .idle, .preparing:
                return AIKitUILocalization.string("Preparing…")
            case .thinking:
                return AIKitUILocalization.string("Thinking…")
            case .callingTool(let name):
                return AIKitUILocalization.string("Calling \(name)…")
            case .verifying:
                return AIKitUILocalization.string("Checking the result…")
            case .externalWork(let status):
                // The host's text (e.g. the workflow's resolved finishing
                // tool — "Creating Entry…") arrives ready to display and
                // host-localized; only the fallback is ours.
                return status ?? AIKitUILocalization.string("Thinking…")
            }
        }
        if let failureReason {
            return failureReason
        }
        return AIKitUILocalization.string("Idle")
    }
}

extension OrchestratorPhase {
    var activityLabel: String {
        switch self {
        case .idle: return AIKitUILocalization.string("Idle")
        case .preparing: return AIKitUILocalization.string("Preparing")
        case .thinking: return AIKitUILocalization.string("Thinking")
        case .callingTool(let name): return AIKitUILocalization.string("Calling \(name)")
        case .verifying: return AIKitUILocalization.string("Checking result")
        case .externalWork(let status): return status ?? AIKitUILocalization.string("Thinking")
        }
    }
}

extension UsageEvent.Kind {
    var detailLabel: String {
        switch self {
        case .userInstruction: return AIKitUILocalization.string("User intent")
        case .toolInvoked: return AIKitUILocalization.string("Tool call")
        case .toolResult: return AIKitUILocalization.string("Tool result")
        case .llmResponse: return AIKitUILocalization.string("LLM response")
        case .error: return AIKitUILocalization.string("Error")
        }
    }

    var rawDetailTitle: String {
        switch self {
        case .llmResponse: return AIKitUILocalization.string("Raw LLM Response")
        case .toolInvoked: return AIKitUILocalization.string("Raw Tool Call")
        case .toolResult: return AIKitUILocalization.string("Raw Tool Result")
        case .userInstruction: return AIKitUILocalization.string("Raw User Intent")
        case .error: return AIKitUILocalization.string("Raw Error")
        }
    }

    var detailSystemImage: String {
        switch self {
        case .userInstruction: return "text.bubble"
        case .toolInvoked: return "wrench.and.screwdriver"
        case .toolResult: return "checkmark.rectangle"
        case .llmResponse: return "sparkles"
        case .error: return "exclamationmark.triangle"
        }
    }
}

extension AIKitConfigurationChange {
    var title: String {
        let target: String
        if let section, let key {
            target = "\(section.rawValue).\(key)"
        } else {
            target = AIKitUILocalization.string("all")
        }
        return AIKitUILocalization.string("\(source) updated \(target)")
    }
}

extension View {
    /// The one inset-container treatment — a soft filled surface inside a
    /// single hairline and one continuous curve — shared by every editable
    /// place in the UI: trailing value fields, the system-prompt editor, the
    /// panel's input. One curve, one hairline, so "a place you can type"
    /// looks the same everywhere it appears.
    func aiKitContainerStyle(
        cornerRadius: CGFloat = AIKitMetrics.fieldRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.thinMaterial, in: shape)
            .overlay {
                shape.strokeBorder(.separator.opacity(0.36), lineWidth: 0.5)
            }
    }

    /// Inset pill treatment for an inline value field, so a trailing text
    /// field reads as an editable target rather than text adrift in a row.
    /// Built on ``aiKitContainerStyle`` so it shares the same hairline.
    func aiKitFieldStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .frame(width: AIKitMetrics.fieldWidth)
            .aiKitContainerStyle()
    }

    func aiKitTextFieldRowStyle() -> some View {
        labeledContentStyle(AIKitTextFieldRowStyle())
    }

    @ViewBuilder
    func chatbotCapsuleStyle(tint: Color) -> some View {
        aiKitGlassEffect(tint: tint, interactive: true, in: Capsule())
    }

    #if os(iOS)
    func aiKitActiveContext(_ context: ViewContext?) -> some View {
        modifier(AIKitContextLifecycleModifier(context: context))
    }

    func aiKitTabFabOverlay<Content: View>(
        isPresented: Bool,
        @ViewBuilder content: @escaping () -> Content,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(AIKitTabFabOverlayModifier(
            isPresented: isPresented,
            viewContent: content,
            onDismiss: onDismiss
        ))
    }
    #endif
}

extension String {
    var emptyAsNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var configurationSet: Set<String> {
        Set(split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}
