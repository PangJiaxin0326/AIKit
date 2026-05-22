import SwiftUI
import AIKitRuntime

/// Floating assistant entry point. Two modes share the same pet button:
///
/// - ``Mode/assistant`` — the full overlay: a tap-to-expand glass capsule
///   with a text field, voice input, and a long-press detail panel.
/// - ``Mode/voice`` — a pure-voice flow. The button has no capsule: a tap
///   starts listening, silence fires the AI turn, and the assistant speaks
///   back when it needs a follow-up.
public struct AIKitChatbotOverlay: View {
    /// Which interaction model the pet button presents.
    public enum Mode: Sendable {
        /// Text-first overlay with a glass capsule. The default.
        case assistant
        /// Hands-free voice loop driven entirely by the button.
        case voice
    }

    private let orchestrator: Orchestrator
    private let mode: Mode

    @MainActor
    public init(orchestrator: Orchestrator, mode: Mode = .assistant) {
        self.orchestrator = orchestrator
        self.mode = mode
    }

    @ViewBuilder
    public var body: some View {
        switch mode {
        case .assistant:
            AssistantChatbotOverlay(orchestrator: orchestrator)
        case .voice:
            VoiceChatbotOverlay(orchestrator: orchestrator)
        }
    }
}

/// The pure-voice pet button. Renders only a draggable, edge-docked circle
/// whose icon and color reflect the conversation phase.
struct VoiceChatbotOverlay: View {
    @State private var controller: VoiceModeController

    /// Which screen edge the button is docked to, and where along it
    /// (0 = top, 1 = bottom).
    @State private var petEdge: HorizontalEdge = .trailing
    @State private var petVerticalFraction: CGFloat = 1
    @State private var dragTranslation: CGSize = .zero
    /// True while the button is pressed or dragged; drives the touch-down
    /// scale-up.
    @GestureState private var isInteracting = false

    private let petDiameter: CGFloat = 58
    private let edgeInset: CGFloat = 16

    @MainActor
    init(orchestrator: Orchestrator) {
        _controller = State(initialValue: VoiceModeController(orchestrator: orchestrator))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            petButton(in: size)
                .position(center(in: size))
                .animation(.spring(duration: 0.3), value: petEdge)
                .animation(.spring(duration: 0.3), value: petVerticalFraction)
        }
        .onDisappear { controller.abort() }
    }

    private func petButton(in size: CGSize) -> some View {
        ZStack {
            if controller.phase == .listening {
                Circle()
                    .stroke(tint.opacity(0.55), lineWidth: 3)
                    .frame(width: petDiameter, height: petDiameter)
                    .scaleEffect(1 + controller.audioLevel * 0.7)
                    .opacity(1 - controller.audioLevel * 0.55)
                    .animation(.snappy(duration: 0.18), value: controller.audioLevel)
            }
            Circle()
                .fill(tint)
                .frame(width: petDiameter, height: petDiameter)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .overlay {
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeating, isActive: isPulsing)
                }
        }
        .frame(width: petDiameter, height: petDiameter)
        .scaleEffect(isInteracting ? 1.2 : 1)
        .contentShape(Circle())
        .onTapGesture { controller.toggle() }
        .simultaneousGesture(moveGesture(in: size))
        .animation(.spring(duration: 0.2), value: isInteracting)
        .animation(.spring(duration: 0.25), value: controller.phase)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Phase appearance

    private var hasError: Bool {
        controller.phase == .idle && controller.errorMessage != nil
    }

    /// Per-phase fill: accent at rest, red while listening, yellow while the
    /// turn runs, blue while speaking, red on a setup error.
    private var tint: Color {
        if hasError { return .red }
        switch controller.phase {
        case .idle: return .accentColor
        case .listening: return .red
        case .thinking: return .yellow
        case .speaking: return .blue
        }
    }

    private var symbol: String {
        if hasError { return "exclamationmark.triangle.fill" }
        switch controller.phase {
        case .idle: return "pawprint.fill"
        case .listening: return "waveform"
        case .thinking: return "sparkles"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    private var isPulsing: Bool {
        controller.phase == .thinking
    }

    private var accessibilityLabel: String {
        if hasError { return "AIKit voice assistant, error. Tap to retry" }
        switch controller.phase {
        case .idle: return "AIKit voice assistant. Tap to speak"
        case .listening: return "Listening. Tap to cancel"
        case .thinking: return "Working. Say stop, or tap, to cancel"
        case .speaking: return "Speaking. Tap to cancel"
        }
    }

    // MARK: - Placement

    private func center(in size: CGSize) -> CGPoint {
        let restingX = petEdge == .leading
            ? edgeInset + petDiameter / 2
            : size.width - edgeInset - petDiameter / 2
        let minX = edgeInset + petDiameter / 2
        let maxX = max(minX, size.width - edgeInset - petDiameter / 2)
        let minY = edgeInset + petDiameter / 2
        let maxY = max(minY, size.height - edgeInset - petDiameter / 2)
        let restingY = minY + petVerticalFraction * (maxY - minY)
        return CGPoint(
            x: (restingX + dragTranslation.width).clamped(to: minX...maxX),
            y: (restingY + dragTranslation.height).clamped(to: minY...maxY)
        )
    }

    /// Drag to move; the button snaps to the nearest edge on release. The
    /// 8pt activation distance keeps taps from being stolen.
    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($isInteracting) { _, state, _ in state = true }
            .onChanged { dragTranslation = $0.translation }
            .onEnded { value in
                let minY = edgeInset + petDiameter / 2
                let maxY = max(minY, size.height - edgeInset - petDiameter / 2)
                let restingX = petEdge == .leading
                    ? edgeInset + petDiameter / 2
                    : size.width - edgeInset - petDiameter / 2
                let restingY = minY + petVerticalFraction * (maxY - minY)
                let droppedX = restingX + value.translation.width
                let droppedY = (restingY + value.translation.height).clamped(to: minY...maxY)
                withAnimation(.spring(duration: 0.3)) {
                    petEdge = droppedX < size.width / 2 ? .leading : .trailing
                    petVerticalFraction = maxY > minY
                        ? (droppedY - minY) / (maxY - minY)
                        : 0.5
                    dragTranslation = .zero
                }
            }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
