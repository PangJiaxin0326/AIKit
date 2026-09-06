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

struct AssistantChatbotOverlay<DetailContent: View>: View {
    @State private var input: AssistantInputCoordinator
    /// Full assistant panel — opened by a long press on the pet.
    @State private var isDialogPresented = false
    /// Whether the glass capsule (status field + action) is expanded next
    /// to the pet. Toggled by a tap.
    @State private var isExpanded = false
    @State private var selectedMenu = ChatbotMenu.context
    @State private var activityDisplay: OverlayActivityDisplay = .tasks
    @State private var draft = ""
    @State private var capsuleSize: CGSize = .zero
    @State private var floatingSurfaceSize: CGSize = .zero
    @State private var snapshot: OrchestratorSnapshot?
    /// Live orchestrator activity, so the pet reflects any turn on this
    /// orchestrator — not just the overlay's own session.
    @State private var activity: OrchestratorActivity = .idle
    /// True while a long press is being held (before it completes); drives
    /// the press scale-up.
    @GestureState private var longPressing = false
    @FocusState private var fieldFocused: Bool
    /// On-screen keyboard frame (iOS); the floating control sticks just
    /// above it, then returns to the pet's position.
    @State private var keyboardFrame: CGRect?
    #if os(iOS)
    /// Typed keyboard-message observations; registered on appear and
    /// removed on disappear.
    @State private var keyboardObservers: [NotificationCenter.ObservationToken] = []
    #endif

    /// Which screen edge the pet is docked to, and where along it
    /// (0 = top, 1 = bottom). The pet snaps to an edge when a drag ends.
    @State private var petEdge: HorizontalEdge = .trailing
    @State private var petVerticalFraction: CGFloat = 1
    @State private var dragTranslation: CGSize = .zero
    /// True while the pet is pressed or dragged; drives the touch-down
    /// scale-up. Auto-resets when the gesture ends.
    @GestureState private var isInteracting = false

    private let orchestrator: Orchestrator
    private let detailContent: @MainActor (AIKitOverlayContext) -> DetailContent

    private let petDiameter = AIKitMetrics.petDiameter
    private let edgeInset = AIKitMetrics.edgeInset

    @MainActor
    init(
        orchestrator: Orchestrator,
        @ViewBuilder detailContent: @escaping @MainActor (AIKitOverlayContext) -> DetailContent
    ) {
        self.orchestrator = orchestrator
        self.detailContent = detailContent
        _input = State(initialValue: AssistantInputCoordinator(orchestrator: orchestrator))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = proxy.frame(in: .global)
            let keyboardOverlap = keyboardOverlap(in: frame)
            let keyboardVisible = keyboardVisible(in: frame)
            ZStack(alignment: .topLeading) {
                if isExpanded || isDialogPresented {
                    Color.black.opacity(0.15)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .onTapGesture { dismissToButton() }
                        .transition(.opacity)
                }
                if isDialogPresented {
                    dialog
                        .position(x: size.width / 2, y: size.height / 2)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    floatingSurface(in: size)
                        .position(floatingCenter(
                            in: size,
                            keyboardOverlap: keyboardOverlap,
                            keyboardVisible: keyboardVisible
                        ))
                }
            }
            .animation(.spring(duration: 0.24), value: isExpanded)
            .animation(.spring(duration: 0.24), value: isDialogPresented)
            .animation(.spring(duration: 0.25), value: keyboardFrame?.minY)
        }
        .task { await refreshSnapshot() }
        .task {
            for await update in orchestrator.activityUpdates() {
                activity = update
            }
        }
        .onChange(of: activity.isBusy) { _, busy in
            // When a turn finishes (busy → idle, not a failure), drop the
            // stale draft so a completed turn can't be re-sent.
            if !busy && !activity.hasFailed { input.text = "" }
            if !busy {
                Task { await refreshSnapshot() }
            }
        }
        .onChange(of: activity.hasFailed) { _, failed in
            // Surface a failure immediately so the reason panel is visible.
            if failed { withAnimation(.spring(duration: 0.28)) { isExpanded = true } }
        }
        .onChange(of: selectedMenu) { _, menu in
            if menu != .activity { activityDisplay = .tasks }
        }
        .onDisappear { cancelVoiceInput() }
        #if os(iOS)
        .onAppear(perform: registerKeyboardObservers)
        .onDisappear(perform: removeKeyboardObservers)
        #endif
    }

    #if os(iOS)
    private func registerKeyboardObservers() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(of: UIScreen.self, for: .keyboardWillChangeFrame) { message in
                keyboardFrame = message.endFrame
            },
            center.addObserver(of: UIScreen.self, for: .keyboardWillHide) { _ in
                keyboardFrame = nil
            },
        ]
    }

    private func removeKeyboardObservers() {
        for token in keyboardObservers {
            NotificationCenter.default.removeObserver(token)
        }
        keyboardObservers = []
    }
    #endif

    /// The pet circle plus its tap / long-press / drag recognizers. Used
    /// standalone when collapsed and inside the capsule when expanded.
    private func petButton(in size: CGSize) -> some View {
        Image(systemName: petSymbol)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: petDiameter, height: petDiameter)
            .contentShape(Circle())
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: activity.isBusy)
            .scaleEffect((longPressing || isInteracting) ? 1.2 : 1)
            .onTapGesture { toggleExpanded() }
            // Recognized independently of the drag, so it fires the
            // instant the 1s hold elapses — not on finger release.
            .simultaneousGesture(isExpanded ? nil :
                LongPressGesture(minimumDuration: 1.0, maximumDistance: 24)
                    .updating($longPressing) { pressing, state, _ in
                        state = pressing
                    }
                    .onEnded { _ in openFullPanel() },
            )
            .simultaneousGesture(isExpanded ? nil : moveGesture(in: size))
            .animation(.spring(duration: 0.2), value: longPressing)
            .animation(.spring(duration: 0.2), value: isInteracting)
            .accessibilityLabel(petAccessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    /// Yellow while a turn runs, red after a failure, tint when idle.
    private var petFill: Color {
        if activity.hasFailed { return .red }
        if activity.isBusy { return .yellow }
        return .accentColor
    }

    /// A per-phase glyph so the pet says *what* it is doing, not just "busy".
    private var petSymbol: String {
        if activity.hasFailed { return "exclamationmark.triangle.fill" }
        guard activity.isBusy else { return "pawprint.fill" }
        switch activity.phase {
        case .idle, .preparing: return "hourglass"
        case .thinking, .externalWork: return "sparkles"
        case .callingTool: return "wrench.and.screwdriver.fill"
        case .verifying: return "checkmark.shield.fill"
        }
    }

    private var petAccessibilityLabel: String {
        if activity.hasFailed {
            return AIKitUILocalization.string("AIKit assistant, failed")
        }
        if activity.isBusy {
            return AIKitUILocalization.string("AIKit assistant, \(activity.aiKitLocalizedStatusText)")
        }
        return AIKitUILocalization.string("AIKit assistant")
    }

    // MARK: - Pet placement

    /// Pet center while resting: derived from the docked edge and vertical
    /// fraction, clamped so the pet stays fully on screen with `edgeInset`
    /// padding.
    private func restingCenter(in size: CGSize) -> CGPoint {
        let x = petEdge == .leading
            ? edgeInset + petDiameter / 2
            : size.width - edgeInset - petDiameter / 2
        let minY = edgeInset + petDiameter / 2
        let maxY = max(minY, size.height - edgeInset - petDiameter / 2)
        let y = minY + petVerticalFraction * (maxY - minY)
        return CGPoint(x: x, y: y.clamped(to: minY...maxY))
    }

    /// Center for the rendered floating surface, switching between the
    /// expanded failure/capsule stack and the collapsed pet button.
    private func floatingCenter(
        in size: CGSize,
        keyboardOverlap: CGFloat,
        keyboardVisible: Bool
    ) -> CGPoint {
        isExpanded
            ? capsuleCenter(
                in: size,
                keyboardOverlap: keyboardOverlap,
                keyboardVisible: keyboardVisible
              )
            : liveCenter(
                in: size,
                keyboardOverlap: keyboardOverlap,
                keyboardVisible: keyboardVisible
              )
    }

    /// Pet center during an in-progress drag: follows the finger but stays
    /// within the on-screen bounds and above the keyboard.
    private func liveCenter(
        in size: CGSize,
        keyboardOverlap: CGFloat,
        keyboardVisible: Bool
    ) -> CGPoint {
        let base = restingCenter(in: size)
        let minX = edgeInset + petDiameter / 2
        let maxX = max(minX, size.width - edgeInset - petDiameter / 2)
        let height = floatingControlHeight
        let minY = edgeInset + height / 2
        let maxY = max(
            minY,
            maxFloatingCenterY(
                in: size,
                controlHeight: height,
                keyboardOverlap: keyboardOverlap
            )
        )
        let targetY = keyboardVisible && dragTranslation == .zero
            ? maxY
            : base.y + dragTranslation.height
        return CGPoint(
            x: (base.x + dragTranslation.width).clamped(to: minX...maxX),
            y: targetY.clamped(to: minY...maxY)
        )
    }

    /// Drag to move: the pet follows the finger and snaps to the nearest
    /// edge on release. Tap and long-press are separate recognizers, so this
    /// only needs an 8pt activation distance to avoid stealing taps.
    private func moveGesture(in size: CGSize) -> some Gesture {
        // Measure in the global space: the pet is repositioned every frame
        // from `dragTranslation`, so a local space would move with it and
        // feed back into the translation, making the pet jitter.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($isInteracting) { _, state, _ in state = true }
            .onChanged { value in
                if isExpanded {
                    fieldFocused = false
                    withAnimation(.spring(duration: 0.2)) { isExpanded = false }
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                let base = restingCenter(in: size)
                let minY = edgeInset + petDiameter / 2
                let maxY = max(minY, size.height - edgeInset - petDiameter / 2)
                let droppedX = base.x + value.translation.width
                let droppedY = (base.y + value.translation.height).clamped(to: minY...maxY)
                withAnimation(.spring(duration: 0.3)) {
                    petEdge = droppedX < size.width / 2 ? .leading : .trailing
                    petVerticalFraction = maxY > minY ? (droppedY - minY) / (maxY - minY) : 0.5
                    dragTranslation = .zero
                }
            }
    }

    // MARK: - Tap / long-press actions

    private func toggleExpanded() {
        withAnimation(.spring(duration: 0.28)) { isExpanded.toggle() }
        if isExpanded {
            isDialogPresented = false
            Task { await refreshSnapshot() }
        } else {
            fieldFocused = false
        }
    }

    private func openFullPanel() {
        fieldFocused = false
        activityDisplay = .tasks
        withAnimation(.spring(duration: 0.24)) {
            isExpanded = false
            isDialogPresented = true
        }
        Task { await refreshSnapshot() }
    }

    /// Sends the capsule's text. After a failure the previous request and
    /// the failure reason are folded in so the model treats the follow-up
    /// as a clarification of the same request, not a brand-new one.
    private func sendCapsule() {
        input.sendCurrentText(activity: activity)
    }

    private var overlayContext: AIKitOverlayContext {
        AIKitOverlayContext(snapshot: snapshot)
    }

    private func startVoiceRecording() {
        fieldFocused = false
        input.startVoiceRecording(activity: activity)
    }

    private func finishVoiceRecording() {
        input.finishVoiceRecording(activity: activity)
    }

    private func cancelVoiceInput() {
        input.cancelVoiceInput()
    }

    private func clearVoiceError() {
        input.clearVoiceError()
        fieldFocused = true
    }

    private func cancelCurrentWork() {
        input.cancelCurrentWork()
    }

    private func dismissToButton() {
        fieldFocused = false
        withAnimation(.spring(duration: 0.24)) {
            isExpanded = false
            isDialogPresented = false
        }
    }

    /// Clears a sticky failure (returns the orchestrator to idle) and
    /// collapses the capsule.
    private func dismissFailure() {
        fieldFocused = false
        input.dismissFailure()
        withAnimation(.spring(duration: 0.24)) { isExpanded = false }
    }

    // MARK: - Glass capsule

    private let capsuleSpacing: CGFloat = 0
    private let capsuleContentPadding: CGFloat = 12
    private let failurePanelSpacing: CGFloat = 10

    @ViewBuilder
    private func floatingSurface(in size: CGSize) -> some View {
        VStack(
            alignment: petEdge == .leading ? .leading : .trailing,
            spacing: failurePanelSpacing
        ) {
            if isExpanded, activity.hasFailed, let reason = activity.failureReason {
                reasonPanel(reason)
                    .transition(.opacity)
            }

            floatingControl(in: size)
                .chatbotCapsuleStyle(tint: petFill)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { newSize in
                    capsuleSize = newSize
                }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            floatingSurfaceSize = newSize
        }
    }

    @ViewBuilder
    private func floatingControl(in size: CGSize) -> some View {
        HStack(spacing: capsuleSpacing) {
            petButton(in: size)
            if isExpanded {
                capsuleContent(in: size)
            }
        }
        .frame(width: floatingControlWidth(in: size), alignment: .leading)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func capsuleContent(in size: CGSize) -> some View {
        AssistantInputBar(
            text: Binding(
                get: { input.text },
                set: { input.text = $0 }
            ),
            focused: $fieldFocused,
            activity: activity,
            voiceLevel: input.voiceInput.voiceLevel,
            isRecording: input.voiceInput.isRecording,
            isVoiceTranscribing: input.voiceInput.isVoiceTranscribing,
            voiceError: input.voiceInput.voiceError,
            horizontalPadding: capsuleContentPadding,
            onSubmit: sendCapsule,
            onStartVoiceRecording: startVoiceRecording,
            onFinishVoiceRecording: finishVoiceRecording,
            onCancelCurrentWork: cancelCurrentWork,
            onDismissFailure: dismissFailure,
            onTextChanged: input.clearVoiceError,
            onClearVoiceError: clearVoiceError
        )
        .frame(width: capsuleContentWidth(in: size))
    }

    private func reasonPanel(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: AIKitMetrics.controlRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AIKitMetrics.controlRadius, style: .continuous)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// Centers the expanded floating surface while keeping the capsule row
    /// docked to the pet's edge — or pinned just above the keyboard.
    private func capsuleCenter(
        in size: CGSize,
        keyboardOverlap: CGFloat,
        keyboardVisible: Bool
    ) -> CGPoint {
        let controlWidth = floatingControlWidth(in: size)
        let controlHeight = floatingControlHeight
        let surfaceWidth = max(floatingSurfaceSize.width, controlWidth)
        let surfaceHeight = max(floatingSurfaceSize.height, controlHeight)

        let controlMinX = edgeInset + controlWidth / 2
        let controlMaxX = size.width - edgeInset - controlWidth / 2
        let controlX = controlMaxX >= controlMinX
            ? (petEdge == .leading ? controlMinX : controlMaxX)
            : size.width / 2
        let surfaceXOffset = (surfaceWidth - controlWidth) / 2
        let targetX = petEdge == .leading
            ? controlX + surfaceXOffset
            : controlX - surfaceXOffset
        let minX = edgeInset + surfaceWidth / 2
        let maxX = size.width - edgeInset - surfaceWidth / 2
        let x = maxX >= minX
            ? targetX.clamped(to: minX...maxX)
            : size.width / 2

        let controlMinY = edgeInset + controlHeight / 2
        let controlMaxY = max(
            controlMinY,
            maxFloatingCenterY(
                in: size,
                controlHeight: controlHeight,
                keyboardOverlap: keyboardOverlap
            )
        )
        let targetControlY = keyboardVisible
            ? controlMaxY
            : restingCenter(in: size).y
        let controlY = targetControlY.clamped(to: controlMinY...controlMaxY)
        let surfaceYOffset = (surfaceHeight - controlHeight) / 2
        let targetY = controlY - surfaceYOffset
        let minY = edgeInset + surfaceHeight / 2
        let maxY = max(
            minY,
            maxFloatingCenterY(
                in: size,
                controlHeight: surfaceHeight,
                keyboardOverlap: keyboardOverlap
            )
        )

        return CGPoint(x: x, y: targetY.clamped(to: minY...maxY))
    }

    private var floatingControlHeight: CGFloat {
        max(capsuleSize.height, petDiameter)
    }

    private func floatingControlWidth(in size: CGSize) -> CGFloat {
        petDiameter + (isExpanded ? capsuleSpacing + capsuleContentWidth(in: size) : 0)
    }

    private func capsuleContentWidth(in size: CGSize) -> CGFloat {
        max(0, size.width - edgeInset * 2 - petDiameter - capsuleSpacing)
    }

    private func maxFloatingCenterY(
        in size: CGSize,
        controlHeight: CGFloat,
        keyboardOverlap: CGFloat
    ) -> CGFloat {
        let screenLimit = size.height - edgeInset - controlHeight / 2
        guard keyboardOverlap > 0 else { return screenLimit }
        let keyboardLimit = size.height - keyboardOverlap - 8 - controlHeight / 2
        return min(screenLimit, keyboardLimit)
    }

    private func keyboardOverlap(in frame: CGRect) -> CGFloat {
        guard let keyboardFrame else { return 0 }
        return min(frame.height, max(0, frame.maxY - keyboardFrame.minY))
    }

    private func keyboardVisible(in frame: CGRect) -> Bool {
        guard let keyboardFrame else { return false }
        return !keyboardFrame.isEmpty && keyboardFrame.minY <= frame.maxY
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 12) {
            dialogHeader
            detailContent(overlayContext)
                .frame(maxWidth: .infinity, alignment: .leading)
            AssistantRuntimeDetailContent(
                snapshot: snapshot,
                activity: activity,
                selectedMenu: $selectedMenu,
                activityDisplay: $activityDisplay,
                maxContentHeight: 260
            )

            dialogTranscript
            dialogInput
        }
        .padding(AIKitMetrics.panelPadding)
        .frame(maxWidth: AIKitMetrics.panelWidth)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: AIKitMetrics.panelRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AIKitMetrics.panelRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .animation(.snappy(duration: 0.2), value: selectedMenu)
    }

    private var dialogHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Color.accentColor.gradient,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            aiKitText("AIKit Assistant")
                .font(.headline)
            Spacer(minLength: 8)
            Button {
                Task { await refreshSnapshot() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.background.secondary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(aiKitText("Refresh"))
            Button {
                withAnimation(.spring(duration: 0.24)) { isDialogPresented = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.background.secondary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(aiKitText("Close"))
        }
    }

    @ViewBuilder
    private var dialogTranscript: some View {
        if !input.session.reasoningText.isEmpty {
            Text(input.session.reasoningText)
                .font(.caption)
                .italic()
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !input.session.streamingText.isEmpty {
            Text(input.session.streamingText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = input.session.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dialogInput: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                AIKitUILocalization.string("Prompt"),
                text: $draft,
                prompt: aiKitText("Prompt"),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .disabled(input.session.isRunning)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .aiKitContainerStyle()
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(input.session.isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Send"))
        }
    }

    private func submit() {
        let instruction = draft
        draft = ""
        Task {
            await input.session.send(instruction)
            await refreshSnapshot()
        }
    }

    private func refreshSnapshot() async {
        snapshot = await orchestrator.snapshot(recentActivityLimit: 24, recentTaskLimit: 8)
    }
}

public extension View {
    @available(*, deprecated, message: "Use aiChatbotOverlay(conversation:).")
    func aiChatbotOverlay(
        orchestrator: Orchestrator,
        mode: AIKitChatbotOverlayMode = .assistant
    ) -> some View {
        overlay {
            AIKitChatbotOverlay(orchestrator: orchestrator, mode: mode)
        }
    }

    @available(*, deprecated, message: "Use aiChatbotOverlay(conversation:mode:detailContent:).")
    func aiChatbotOverlay<DetailContent: View>(
        orchestrator: Orchestrator,
        mode: AIKitChatbotOverlayMode = .assistant,
        @ViewBuilder detailContent: @escaping @MainActor (AIKitOverlayContext) -> DetailContent
    ) -> some View {
        overlay {
            AIKitChatbotOverlay(
                orchestrator: orchestrator,
                mode: mode,
                detailContent: detailContent
            )
        }
    }
}

#if os(macOS)
/// macOS entry point for AIKit's assistant runtime detail surface.
///
/// This wraps the shared ``AssistantRuntimeDetailContent`` used by the
/// assistant overlay, while owning the macOS-friendly snapshot/activity state
/// needed by hosts that want to place the detail surface in a window, panel, or
/// debug view.
public struct AssistantRuntimeDetailView: View {
    private let orchestrator: Orchestrator
    private let title: String
    private let maxContentHeight: CGFloat

    @State private var snapshot: OrchestratorSnapshot?
    @State private var activity: OrchestratorActivity = .idle
    @State private var selectedMenu = ChatbotMenu.context
    @State private var activityDisplay: OverlayActivityDisplay = .tasks

    public init(
        orchestrator: Orchestrator,
        title: String = "Assistant Runtime",
        maxContentHeight: CGFloat = 420
    ) {
        self.orchestrator = orchestrator
        self.title = title
        self.maxContentHeight = maxContentHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            AssistantRuntimeDetailContent(
                snapshot: snapshot,
                activity: activity,
                selectedMenu: $selectedMenu,
                activityDisplay: $activityDisplay,
                maxContentHeight: maxContentHeight
            )
        }
        .padding(AIKitMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AIKitMetrics.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AIKitMetrics.cardRadius)
                .strokeBorder(.separator.opacity(0.36), lineWidth: 0.5)
        }
        .task { await refreshSnapshot() }
        .task {
            for await update in orchestrator.activityUpdates() {
                activity = update
            }
        }
        .onChange(of: activity.isBusy) { _, busy in
            if !busy {
                Task { await refreshSnapshot() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.headline)
                Text(activity.aiKitLocalizedStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task { await refreshSnapshot() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(AIKitUILocalization.string("Refresh runtime details"))
        }
    }

    private func refreshSnapshot() async {
        snapshot = await orchestrator.snapshot(recentActivityLimit: 24, recentTaskLimit: 8)
    }
}
#endif

