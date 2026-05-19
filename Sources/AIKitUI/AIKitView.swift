import Foundation
import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#endif
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety
import MultiModalKit

/// Drives one `Orchestrator` turn and exposes its events for SwiftUI.
@MainActor
@Observable
public final class AIKitSession {
    public struct Line: Identifiable, Sendable {
        public let id = UUID()
        public let role: String
        public let text: String
    }

    public private(set) var streamingText: String = ""
    /// Live model reasoning for the in-flight turn. Cleared when the final
    /// answer arrives. Empty when the model emits no reasoning.
    public private(set) var reasoningText: String = ""
    public private(set) var lines: [Line] = []
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Cumulative token usage across every turn this session has run.
    public private(set) var totalUsage = TokenUsage.zero

    private let orchestrator: Orchestrator

    public init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    private static func describe(_ error: any Error) -> String {
        if let violation = error as? GuardrailViolation {
            return "Blocked by \(violation.railID) at \(violation.stage.rawValue): \(violation.reason)"
        }
        if let iteration = error as? IterationLimitExceeded {
            return "Stopped after reaching the \(iteration.limit)-iteration limit."
        }
        if let deadline = error as? TurnDeadlineExceeded {
            return "Stopped after exceeding the \(Int(deadline.budget))s turn budget."
        }
        if let llmError = error as? LLMError {
            return llmError.errorDescription ?? "\(llmError)"
        }
        if let configuration = error as? AIKitConfigurationError {
            return configuration.message
        }
        return "\(error)"
    }

    public func send(_ instruction: String) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        isRunning = true
        lastError = nil
        streamingText = ""
        reasoningText = ""
        lines.append(Line(role: "you", text: trimmed))

        do {
            for try await event in await orchestrator.run(trimmed) {
                switch event {
                case .llmDelta(let delta):
                    streamingText += delta
                case .reasoningDelta(let delta):
                    reasoningText += delta
                case .toolCall(let name, _):
                    lines.append(Line(role: "tool", text: "Calling \(name)"))
                case .toolResult(let name, let output):
                    lines.append(Line(
                        role: "tool",
                        text: "\(name): \(String(decoding: output, as: UTF8.self))"
                    ))
                case .verification(let stage, let outcome):
                    switch outcome {
                    case .pass:
                        break
                    case .warn(let reason):
                        lines.append(Line(role: "warn", text: "[\(stage.rawValue)] \(reason)"))
                    case .block(let reason):
                        lines.append(Line(role: "blocked", text: "[\(stage.rawValue)] \(reason)"))
                    }
                case .usage(let usage):
                    totalUsage = TokenUsage(
                        inputTokens: totalUsage.inputTokens + usage.inputTokens,
                        outputTokens: totalUsage.outputTokens + usage.outputTokens
                    )
                case .finalAnswer(let text):
                    lines.append(Line(role: "assistant", text: text))
                    streamingText = ""
                    reasoningText = ""
                case .failure(let reason):
                    lastError = reason
                    lines.append(Line(role: "failed", text: reason))
                    streamingText = ""
                    reasoningText = ""
                case .error(let error):
                    let message = Self.describe(error)
                    lastError = message
                    lines.append(Line(role: "error", text: message))
                case .promptBuilt:
                    break
                }
            }
        } catch {
            let message = Self.describe(error)
            lastError = message
            lines.append(Line(role: "error", text: message))
        }
        isRunning = false
    }
}

/// A SwiftUI state-management surface for AIKit's Core, Capability, Runtime,
/// and Safety configuration.
public struct AIKitView: View {
    @State private var model: AIKitConfigurationViewModel

    private let orchestrator: Orchestrator?

    @MainActor
    public init(
        configurationStore: AIKitConfigurationStore = AIKitConfigurationStore(),
        toolRegistry: ToolRegistry? = nil
    ) {
        self.orchestrator = nil
        _model = State(initialValue: AIKitConfigurationViewModel(
            store: configurationStore,
            toolRegistry: toolRegistry
        ))
    }

    @MainActor
    public init(
        orchestrator: Orchestrator,
        configurationStore: AIKitConfigurationStore = AIKitConfigurationStore(),
        toolRegistry: ToolRegistry? = nil
    ) {
        self.orchestrator = orchestrator
        _model = State(initialValue: AIKitConfigurationViewModel(
            store: configurationStore,
            toolRegistry: toolRegistry
        ))
    }

    @ViewBuilder
    public var body: some View {
        dashboard
            .task { await model.load() }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                coreSection
                capabilitySection
                runtimeSection
                safetySection
                if !model.recentChanges.isEmpty {
                    changeLogSection
                }
                resetFooter
            }
            .padding()
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AIKit")
                    .font(.title2.weight(.semibold))
                Text("Core, Capability, Runtime, Safety")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var coreSection: some View {
        AIKitConfigurationSection(title: "Core", systemImage: "cpu") {
            LabeledContent("Provider") {
                TextField("Provider", text: binding(\.core.providerName))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Model") {
                TextField("Model", text: binding(\.core.model))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Base URL") {
                TextField("Base URL", text: optionalStringBinding(\.core.baseURL))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Timeout") {
                TextField("Seconds", text: optionalDoubleBinding(\.core.timeout))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Temperature") {
                TextField("Default", text: optionalDoubleBinding(\.core.temperature))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Max tokens") {
                TextField("Default", text: optionalIntBinding(\.core.maxTokens))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var capabilitySection: some View {
        AIKitConfigurationSection(title: "Capability", systemImage: "slider.horizontal.3") {
            LabeledContent("Context") {
                TextField("Display name", text: binding(\.capability.contextDisplayName))
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("System prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: binding(\.capability.systemPromptFragment))
                    .font(.body)
                    .frame(minHeight: 84)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }
            }
            LabeledContent("Memory window") {
                Stepper(
                    "\(model.configuration.capability.memoryLimit)",
                    value: binding(\.capability.memoryLimit),
                    in: 0...500
                )
            }
            if model.availableTools.isEmpty {
                LabeledContent("Enabled tools") {
                    TextField(
                        "Comma-separated",
                        text: setBinding(\.capability.enabledToolNames)
                    )
                    .multilineTextAlignment(.trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enabled tools")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(model.availableTools) { tool in
                        Toggle(tool.name, isOn: toolBinding(tool.name))
                    }
                }
            }
        }
    }

    private var runtimeSection: some View {
        AIKitConfigurationSection(title: "Runtime", systemImage: "point.3.connected.trianglepath.dotted") {
            Toggle("Stream responses", isOn: binding(\.runtime.streamsResponses))
            LabeledContent("Max iterations") {
                Stepper(
                    "\(model.configuration.runtime.maxIterations)",
                    value: binding(\.runtime.maxIterations),
                    in: 1...50
                )
            }
            LabeledContent("Turn budget") {
                TextField("Seconds", text: optionalDoubleBinding(\.runtime.maxTurnDuration))
                    .multilineTextAlignment(.trailing)
            }
            Picker("Tool fallback", selection: binding(\.runtime.toolCallFallback)) {
                ForEach(AIKitConfiguration.ToolCallFallbackMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var safetySection: some View {
        AIKitConfigurationSection(title: "Safety", systemImage: "shield.lefthalf.filled") {
            Toggle("PII redaction", isOn: binding(\.safety.piiRedactionEnabled))
            Toggle("Injection sniffing", isOn: binding(\.safety.injectionSniffingEnabled))
            LabeledContent("Output cap") {
                TextField("Characters", text: optionalIntBinding(\.safety.outputLengthLimit))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Guardrails") {
                TextField("Comma-separated", text: setBinding(\.safety.enabledGuardrailIDs))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Tool allowlist") {
                TextField("Comma-separated", text: setBinding(\.safety.allowlistedToolNames))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var changeLogSection: some View {
        AIKitConfigurationSection(title: "Configuration Activity", systemImage: "clock") {
            ForEach(model.recentChanges) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.title)
                        .font(.subheadline)
                    Text(change.valueDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var resetFooter: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                model.resetToDefaults()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { model.update(keyPath, to: $0) }
        )
    }

    private func optionalStringBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, String?>
    ) -> Binding<String> {
        Binding(
            get: { model.configuration[keyPath: keyPath] ?? "" },
            set: { model.update(keyPath, to: $0.emptyAsNil) }
        )
    }

    private func optionalDoubleBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Double?>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let value = model.configuration[keyPath: keyPath] else { return "" }
                return String(value)
            },
            set: { model.update(keyPath, to: Double($0)) }
        )
    }

    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Int?>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let value = model.configuration[keyPath: keyPath] else { return "" }
                return String(value)
            },
            set: { model.update(keyPath, to: Int($0)) }
        )
    }

    private func setBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Set<String>>
    ) -> Binding<String> {
        Binding(
            get: { model.configuration[keyPath: keyPath].sorted().joined(separator: ", ") },
            set: { model.update(keyPath, to: $0.configurationSet) }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.configuration.capability.enabledToolNames.contains(name) },
            set: { isEnabled in
                model.update { configuration in
                    if isEnabled {
                        configuration.capability.enabledToolNames.insert(name)
                    } else {
                        configuration.capability.enabledToolNames.remove(name)
                    }
                }
            }
        )
    }
}

/// Floating assistant entry point for apps that want AIKit available above
/// their existing view hierarchy.
public struct AIKitChatbotOverlay: View {
    @State private var session: AIKitSession
    @StateObject private var voiceRecorder = AudioRecorder()
    /// Full assistant panel — opened by a long press on the pet.
    @State private var isDialogPresented = false
    /// Whether the glass capsule (status field + action) is expanded next
    /// to the pet. Toggled by a tap.
    @State private var isExpanded = false
    @State private var selectedMenu = ChatbotMenu.context
    @State private var draft = ""
    @State private var capsuleDraft = ""
    @State private var isVoiceTranscribing = false
    @State private var voiceError: String?
    @State private var voiceTask: Task<Void, Never>?
    @State private var capsuleSize: CGSize = .zero
    /// The last instruction sent from the capsule, carried as context into
    /// a follow-up after a failure.
    @State private var lastInstruction = ""
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

    /// Which screen edge the pet is docked to, and where along it
    /// (0 = top, 1 = bottom). The pet snaps to an edge when a drag ends.
    @State private var petEdge: HorizontalEdge = .trailing
    @State private var petVerticalFraction: CGFloat = 1
    @State private var dragTranslation: CGSize = .zero
    /// True while the pet is pressed or dragged; drives the touch-down
    /// scale-up. Auto-resets when the gesture ends.
    @GestureState private var isInteracting = false

    private let orchestrator: Orchestrator

    private let petDiameter: CGFloat = 58
    private let edgeInset: CGFloat = 16

    @MainActor
    public init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
        _session = State(initialValue: AIKitSession(orchestrator: orchestrator))
    }

    public var body: some View {
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
                    floatingControl(in: size)
                        .chatbotCapsuleStyle(tint: petFill)
                        .onGeometryChange(for: CGSize.self) { proxy in
                            proxy.size
                        } action: { newSize in
                            capsuleSize = newSize
                        }
                        .position(floatingCenter(
                            in: size,
                            keyboardOverlap: keyboardOverlap,
                            keyboardVisible: keyboardVisible
                        ))
                        .overlay {
                            if isExpanded, activity.hasFailed, let reason = activity.failureReason {
                                reasonPanel(reason)
                                    .position(floatingCenter(
                                        in: size,
                                        keyboardOverlap: keyboardOverlap,
                                        keyboardVisible: keyboardVisible
                                    ))
                                    .offset(y: -50)
                            }
                        }
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
            if !busy && !activity.hasFailed { capsuleDraft = "" }
        }
        .onChange(of: activity.hasFailed) { _, failed in
            // Surface a failure immediately so the reason panel is visible.
            if failed { withAnimation(.spring(duration: 0.28)) { isExpanded = true } }
        }
        .onDisappear { cancelVoiceInput() }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )) { note in
            if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect {
                keyboardFrame = frame
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { _ in
            keyboardFrame = nil
        }
        #endif
    }

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
        case .thinking: return "sparkles"
        case .callingTool: return "wrench.and.screwdriver.fill"
        case .verifying: return "checkmark.shield.fill"
        }
    }

    private var petAccessibilityLabel: String {
        if activity.hasFailed { return "AIKit assistant, failed" }
        if activity.isBusy { return "AIKit assistant, \(activity.statusText)" }
        return "AIKit assistant"
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

    /// Center for the rendered floating control, switching between the
    /// expanded capsule row and the collapsed pet button.
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
        sendCapsuleText(capsuleDraft)
    }

    private func sendCapsuleText(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !activity.isBusy else { return }
        capsuleDraft = ""
        let instruction = activity.hasFailed
            ? contextualFollowUp(
                previous: lastInstruction,
                reason: activity.failureReason,
                followUp: text
              )
            : text
        lastInstruction = text
        Task { await session.send(instruction) }
    }

    private var voiceLevel: Double {
        max(voiceRecorder.averagePowerLevel, voiceRecorder.peakPowerLevel * 0.85)
    }

    private func startVoiceRecording() {
        guard !activity.isBusy, !isVoiceTranscribing else { return }
        fieldFocused = false
        capsuleDraft = ""
        voiceError = nil
        voiceTask?.cancel()
        voiceTask = Task { @MainActor in
            do {
                try await PermissionCenter.require(.speechRecognition)
                try Task.checkCancellation()
                _ = try await voiceRecorder.startRecordingWithPermission(
                    configuration: AudioRecordingConfiguration(format: .wav)
                )
            } catch is CancellationError {
                voiceRecorder.cancelRecording()
            } catch {
                voiceError = error.localizedDescription
                voiceRecorder.cancelRecording()
            }
        }
    }

    private func finishVoiceRecording() {
        guard let url = voiceRecorder.stopRecording() else { return }
        transcribeVoiceRecording(at: url)
    }

    private func transcribeVoiceRecording(at url: URL) {
        isVoiceTranscribing = true
        voiceError = nil
        voiceTask?.cancel()
        voiceTask = Task { @MainActor [url] in
            defer {
                isVoiceTranscribing = false
                voiceTask = nil
                try? FileManager.default.removeItem(at: url)
            }

            do {
                let result = try await SpeechTranscriptionService()
                    .transcribeAudioFile(at: url)
                try Task.checkCancellation()

                let text = result.plainText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    voiceError = "No speech detected."
                    return
                }
                sendCapsuleText(text)
            } catch is CancellationError {
                voiceRecorder.cancelRecording()
            } catch {
                voiceError = error.localizedDescription
            }
        }
    }

    private func cancelVoiceInput() {
        voiceTask?.cancel()
        voiceTask = nil
        if voiceRecorder.isRecording {
            voiceRecorder.cancelRecording()
        }
        isVoiceTranscribing = false
    }

    private func contextualFollowUp(
        previous: String,
        reason: String?,
        followUp: String
    ) -> String {
        var parts = ["This is a follow-up to a request you could not complete."]
        if !previous.isEmpty {
            parts.append("Your earlier request was: \"\(previous)\"")
        }
        if let reason, !reason.isEmpty {
            parts.append("It could not be completed because: \(reason)")
        }
        parts.append("Clarification / new instruction: \(followUp)")
        parts.append(
            "Treat the earlier request and this clarification as one request."
        )
        return parts.joined(separator: "\n")
    }

    private func cancelCurrentWork() {
        Task { await orchestrator.cancelActiveTurns() }
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
        Task { await orchestrator.cancelActiveTurns() }
        withAnimation(.spring(duration: 0.24)) { isExpanded = false }
    }

    // MARK: - Glass capsule

    private let capsuleSpacing: CGFloat = 0
    private let capsuleContentPadding: CGFloat = 12

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

    /// The fail-reason panel (when failed) stacked above the capsule row,
    /// aligned to the pet's docked edge so it grows toward screen interior.
    private func capsuleGroup(in size: CGSize) -> some View {
        VStack(
            alignment: petEdge == .leading ? .leading : .trailing,
            spacing: 8
        ) {
            capsuleContent(in: size)
        }
    }

    private func capsuleContent(in size: CGSize) -> some View {
        HStack(spacing: 8) {
            statusField
                .padding(.leading, capsuleContentPadding)
            capsuleActionButton
                .padding(.trailing, capsuleContentPadding)
        }
        .frame(width: capsuleContentWidth(in: size))
    }

    @ViewBuilder
    private var statusField: some View {
        if voiceRecorder.isRecording {
            VoiceWaveformView(level: voiceLevel)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if isVoiceTranscribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if activity.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(activity.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let voiceError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(voiceError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onTapGesture {
                self.voiceError = nil
                fieldFocused = true
            }
        } else {
            TextField(
                activity.hasFailed ? "Add a clarification…" : "Ask the assistant…",
                text: $capsuleDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .focused($fieldFocused)
            .multilineTextAlignment(.leading)
            .submitLabel(.send)
            .onSubmit(sendCapsule)
            .onChange(of: capsuleDraft) { _, _ in voiceError = nil }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var capsuleActionButton: some View {
        let trimmedEmpty = capsuleDraft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if voiceRecorder.isRecording {
            Button(action: finishVoiceRecording) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Stop recording")
        } else if isVoiceTranscribing {
            EmptyView()
        } else if activity.isBusy {
            Button(action: cancelCurrentWork) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Cancel")
        } else if activity.hasFailed && trimmedEmpty {
            Button(action: dismissFailure) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Dismiss")
        } else if trimmedEmpty {
            Button(action: startVoiceRecording) {
                Image(systemName: "mic.fill")
                    .symbolRenderingMode(.monochrome)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.accentColor)
            .disabled(activity.isBusy || isVoiceTranscribing)
            .accessibilityLabel("Start recording")
        } else {
            Button(action: sendCapsule) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Send")
        }
    }

    private func reasonPanel(_ reason: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Centers the capsule group: docked to the pet's edge at the pet's
    /// vertical position — or pinned just above the keyboard.
    private func capsuleCenter(
        in size: CGSize,
        keyboardOverlap: CGFloat,
        keyboardVisible: Bool
    ) -> CGPoint {
        let width = floatingControlWidth(in: size)
        let height = floatingControlHeight
        let minX = edgeInset + width / 2
        let maxX = size.width - edgeInset - width / 2
        let x = maxX >= minX
            ? (petEdge == .leading ? minX : maxX)
            : size.width / 2
        let minY = edgeInset + height / 2
        let maxY = max(
            minY,
            maxFloatingCenterY(
                in: size,
                controlHeight: height,
                keyboardOverlap: keyboardOverlap
            )
        )
        let targetY = keyboardVisible
            ? maxY
            : restingCenter(in: size).y
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
            HStack {
                Label("AIKit Assistant", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refreshSnapshot() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button {
                    withAnimation(.spring(duration: 0.24)) {
                        isDialogPresented = false
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            Picker("Menu", selection: $selectedMenu) {
                ForEach(ChatbotMenu.allCases) { menu in
                    Text(menu.rawValue).tag(menu)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            ScrollView {
                menuContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            if !session.reasoningText.isEmpty {
                Text(session.reasoningText)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }

            if !session.streamingText.isEmpty {
                Text(session.streamingText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Prompt", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(session.isRunning)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(session.isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        switch selectedMenu {
        case .context:
            contextContent
        case .tools:
            toolsContent
        case .activity:
            activityContent
        }
    }

    private var contextContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot, !snapshot.contexts.isEmpty {
                ForEach(snapshot.contexts) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(context.id.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !context.systemPromptFragment.isEmpty {
                            Text(context.systemPromptFragment)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if !context.toolNames.isEmpty {
                            Text(context.toolNames.sorted().joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No active context")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot, !snapshot.availableTools.isEmpty {
                ForEach(snapshot.availableTools) { tool in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.name)
                            .font(.subheadline.weight(.medium))
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No tools available")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            let activity = snapshot?.recentActivities ?? []
            if activity.isEmpty && session.lines.isEmpty {
                Text("No recent activity")
                    .foregroundStyle(.secondary)
            }
            ForEach(activity) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.kind.rawValue)
                        .font(.caption.weight(.medium))
                    Text(event.payloadText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(session.lines.suffix(8)) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.role.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(line.text)
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func submit() {
        let instruction = draft
        draft = ""
        Task {
            await session.send(instruction)
            await refreshSnapshot()
        }
    }

    private func refreshSnapshot() async {
        snapshot = await orchestrator.snapshot(recentActivityLimit: 12)
    }
}

public typealias ChatbotOverlay = AIKitChatbotOverlay

public extension View {
    func aiChatbotOverlay(orchestrator: Orchestrator) -> some View {
        overlay {
            AIKitChatbotOverlay(orchestrator: orchestrator)
        }
    }
}

@MainActor
@Observable
private final class AIKitConfigurationViewModel {
    var configuration: AIKitConfiguration
    var availableTools: [ToolDescriptor] = []
    var recentChanges: [AIKitConfigurationChange] = []
    var status: String?

    private let store: AIKitConfigurationStore
    private let toolRegistry: ToolRegistry?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: AIKitConfigurationStore, toolRegistry: ToolRegistry?) {
        self.store = store
        self.toolRegistry = toolRegistry
        self.configuration = .standard
    }

    func load() async {
        configuration = await store.snapshot()
        recentChanges = await store.recentChanges(limit: 6)
        if let toolRegistry {
            availableTools = await toolRegistry.registeredDescriptors()
        }
        status = nil
    }

    func update<Value>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value>,
        to value: Value
    ) {
        configuration[keyPath: keyPath] = value
        saveCurrentConfiguration(status: "Saved")
    }

    func update(_ change: (inout AIKitConfiguration) -> Void) {
        change(&configuration)
        saveCurrentConfiguration(status: "Saved")
    }

    func resetToDefaults() {
        configuration = .standard
        saveCurrentConfiguration(status: "Reset")
    }

    private func saveCurrentConfiguration(status: String) {
        saveTask?.cancel()

        let configuration = configuration
        saveTask = Task { [store, configuration] in
            guard !Task.isCancelled else { return }
            await store.replace(with: configuration, source: "AIKitView")
            guard !Task.isCancelled else { return }

            let recentChanges = await store.recentChanges(limit: 6)
            guard !Task.isCancelled else { return }

            self.recentChanges = recentChanges
            self.status = status
        }
    }

    deinit {
        saveTask?.cancel()
    }
}

private struct AIKitConfigurationSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .groupBoxStyle(.automatic)
    }
}

private struct VoiceWaveformView: View {
    let level: Double

    private let barCount = 36
    private let barSpacing: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let barWidth = max(
                    2,
                    (proxy.size.width - barSpacing * CGFloat(barCount - 1)) / CGFloat(barCount)
                )
                HStack(spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(
                                width: barWidth,
                                height: barHeight(index: index, date: timeline.date)
                            )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .center)
            .accessibilityLabel("Recording voice")
        }
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        let clampedLevel = min(1, max(0.04, level))
        let midpoint = Double(barCount - 1) / 2
        let distance = abs(Double(index) - midpoint) / midpoint
        let envelope = 1 - distance * 0.48
        let phase = date.timeIntervalSinceReferenceDate * 8
        let ripple = 0.58 + 0.42 * sin(phase + Double(index) * 0.68)
        let height = 5 + 28 * clampedLevel * envelope * ripple
        return CGFloat(height)
    }
}

private enum ChatbotMenu: String, CaseIterable, Identifiable {
    case context = "Context"
    case tools = "Tools"
    case activity = "Activity"

    var id: String { rawValue }
}

private extension AIKitConfiguration.ToolCallFallbackMode {
    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .enabled: return "On"
        case .disabled: return "Off"
        }
    }
}

private extension AIKitConfigurationChange {
    var title: String {
        let target: String
        if let section, let key {
            target = "\(section.rawValue).\(key)"
        } else {
            target = "all"
        }
        return "\(source) updated \(target)"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension View {
    @ViewBuilder
    func chatbotCapsuleStyle(tint: Color) -> some View {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            glassEffect(.regular.interactive().tint(tint), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(tint.opacity(0.35))
                }
        }
    }
}

private extension String {
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

#Preview {
    AIKitChatbotOverlay(orchestrator: .init(llm: .init(provider: OllamaProvider()), tools: .init(), memory: InMemoryMemoryStore(), contextResolver: .init(), guardrails: .init()))
}
