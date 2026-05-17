import Foundation
import SwiftUI
import Observation
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety

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

    public var body: some View {
        dashboard
            .task { await model.load() }
            .refreshable { await model.load() }
            .overlay {
                if let orchestrator {
                    AIKitChatbotOverlay(orchestrator: orchestrator)
                }
            }
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
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await model.apply() }
            } label: {
                Label("Apply", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
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

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { model.configuration[keyPath: keyPath] = $0 }
        )
    }

    private func optionalStringBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, String?>
    ) -> Binding<String> {
        Binding(
            get: { model.configuration[keyPath: keyPath] ?? "" },
            set: { model.configuration[keyPath: keyPath] = $0.emptyAsNil }
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
            set: { model.configuration[keyPath: keyPath] = Double($0) }
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
            set: { model.configuration[keyPath: keyPath] = Int($0) }
        )
    }

    private func setBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Set<String>>
    ) -> Binding<String> {
        Binding(
            get: { model.configuration[keyPath: keyPath].sorted().joined(separator: ", ") },
            set: { model.configuration[keyPath: keyPath] = $0.configurationSet }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.configuration.capability.enabledToolNames.contains(name) },
            set: { isEnabled in
                if isEnabled {
                    model.configuration.capability.enabledToolNames.insert(name)
                } else {
                    model.configuration.capability.enabledToolNames.remove(name)
                }
            }
        )
    }
}

/// Floating assistant entry point for apps that want AIKit available above
/// their existing view hierarchy.
public struct AIKitChatbotOverlay: View {
    @State private var session: AIKitSession
    /// Full assistant panel — opened by a long press on the pet.
    @State private var isDialogPresented = false
    /// Compact status bubble — toggled by a tap; pet stays visible.
    @State private var isBubblePresented = false
    @State private var selectedMenu = ChatbotMenu.context
    @State private var draft = ""
    @State private var bubbleDraft = ""
    @State private var bubbleSize: CGSize = .zero
    @State private var snapshot: OrchestratorSnapshot?
    /// Live orchestrator activity, so the pet reflects any turn on this
    /// orchestrator — not just the overlay's own session.
    @State private var activity: OrchestratorActivity = .idle
    /// True while a long press is being held (before it completes); drives
    /// the press scale-up.
    @GestureState private var longPressing = false

    /// Which screen edge the pet is docked to, and where along it
    /// (0 = top, 1 = bottom). The pet snaps to an edge when a drag ends.
    @State private var petEdge: HorizontalEdge = .trailing
    @State private var petVerticalFraction: CGFloat = 0.85
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
            let petCenter = liveCenter(in: size)
            ZStack(alignment: .topLeading) {
                if isDialogPresented {
                    dialog
                        .position(x: size.width / 2, y: size.height / 2)
                        .transition(.scale.combined(with: .opacity))
                }
                if isBubblePresented && !isDialogPresented {
                    statusBubble
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                        .position(bubbleCenter(petCenter: petCenter, in: size))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                pet
                    .scaleEffect((longPressing || isInteracting) ? 1.18 : 1)
                    .onTapGesture { toggleBubble() }
                    // Recognized independently of the drag, so it fires the
                    // instant the 2s hold elapses — not on finger release.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 2.0, maximumDistance: 24)
                            .updating($longPressing) { pressing, state, _ in
                                state = pressing
                            }
                            .onEnded { _ in openFullPanel() }
                    )
                    .simultaneousGesture(moveGesture(in: size))
                    .position(petCenter)
                    .animation(.spring(duration: 0.2), value: longPressing)
                    .animation(.spring(duration: 0.2), value: isInteracting)
            }
        }
        .task { await refreshSnapshot() }
        .task {
            for await update in orchestrator.activityUpdates() {
                activity = update
            }
        }
        .onChange(of: activity.isBusy) { _, busy in
            // When a turn finishes (busy → idle, not a failure), drop any
            // stale draft so the working bubble is cleanly replaced by an
            // empty idle prompt and the completed turn can't be re-sent.
            if !busy && !activity.hasFailed { bubbleDraft = "" }
        }
    }

    private var pet: some View {
        ZStack {
            Circle()
                .fill(petFill)
                .frame(width: petDiameter, height: petDiameter)
                .shadow(radius: 10, y: 4)
            Image(systemName: petSymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: activity.isBusy)
        }
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.2), value: activity)
        .accessibilityLabel(petAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// Yellow while a turn runs, red after a failure, tint when idle.
    private var petFill: AnyShapeStyle {
        if activity.hasFailed { return AnyShapeStyle(.red) }
        if activity.isBusy { return AnyShapeStyle(.yellow) }
        return AnyShapeStyle(.tint)
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

    /// Pet center during an in-progress drag: follows the finger but stays
    /// within the on-screen bounds.
    private func liveCenter(in size: CGSize) -> CGPoint {
        let base = restingCenter(in: size)
        let minX = edgeInset + petDiameter / 2
        let maxX = max(minX, size.width - edgeInset - petDiameter / 2)
        let minY = edgeInset + petDiameter / 2
        let maxY = max(minY, size.height - edgeInset - petDiameter / 2)
        return CGPoint(
            x: (base.x + dragTranslation.width).clamped(to: minX...maxX),
            y: (base.y + dragTranslation.height).clamped(to: minY...maxY)
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

    private func toggleBubble() {
        withAnimation(.spring(duration: 0.22)) {
            isBubblePresented.toggle()
        }
        if isBubblePresented {
            isDialogPresented = false
            Task { await refreshSnapshot() }
        }
    }

    private func openFullPanel() {
        withAnimation(.spring(duration: 0.24)) {
            isBubblePresented = false
            isDialogPresented = true
        }
        Task { await refreshSnapshot() }
    }

    private func sendFromBubble() {
        let text = bubbleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !activity.isBusy else { return }
        bubbleDraft = ""
        Task { await session.send(text) }
    }

    private func cancelCurrentWork() {
        Task { await orchestrator.cancelActiveTurns() }
    }

    // MARK: - Status bubble

    /// A compact, state-aware popover anchored to the pet (pet stays
    /// visible): failure reason + cancel + follow-up, the live task while
    /// busy, or a prompt field when idle.
    private var statusBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(bubbleTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(activity.hasFailed ? .red : .primary)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.spring(duration: 0.22)) { isBubblePresented = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            if activity.hasFailed, let reason = activity.failureReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel", role: .cancel, action: cancelCurrentWork)
                        .buttonStyle(.bordered)
                    Spacer()
                }
                followUpField(placeholder: "Try rephrasing…")
            } else if activity.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button("Cancel", role: .cancel, action: cancelCurrentWork)
                    .buttonStyle(.bordered)
            } else {
                followUpField(placeholder: "Ask the assistant…")
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(activity.hasFailed ? AnyShapeStyle(.red.opacity(0.4)) : AnyShapeStyle(.quaternary))
        }
        .shadow(radius: 12, y: 4)
    }

    private var bubbleTitle: String {
        if activity.hasFailed { return "Couldn't do that" }
        if activity.isBusy { return "Working…" }
        return "Assistant"
    }

    private func followUpField(placeholder: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $bubbleDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(activity.isBusy)
                .onSubmit(sendFromBubble)
            Button(action: sendFromBubble) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                activity.isBusy
                || bubbleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    /// Bubble center: docked to the pet's edge, opening above the pet when
    /// there is room and below it otherwise, always kept fully on screen.
    private func bubbleCenter(petCenter: CGPoint, in size: CGSize) -> CGPoint {
        let width = bubbleSize.width
        let height = bubbleSize.height
        let minX = edgeInset + width / 2
        let maxX = size.width - edgeInset - width / 2
        let x = maxX >= minX
            ? (petEdge == .leading ? minX : maxX)
            : size.width / 2
        let gap: CGFloat = 12
        let minY = edgeInset + height / 2
        let maxY = size.height - edgeInset - height / 2
        var y = petCenter.y - petDiameter / 2 - gap - height / 2
        if y < minY {
            y = petCenter.y + petDiameter / 2 + gap + height / 2
        }
        y = maxY >= minY ? y.clamped(to: minY...maxY) : size.height / 2
        return CGPoint(x: x, y: y)
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

    init(store: AIKitConfigurationStore, toolRegistry: ToolRegistry?) {
        self.store = store
        self.toolRegistry = toolRegistry
        self.configuration = .standard
    }

    func load() async {
        configuration = await store.snapshot()
        recentChanges = await store.recentChanges(limit: 6)
        if let toolRegistry {
            availableTools = await toolRegistry.manifest(for: [])
        }
        status = nil
    }

    func apply() async {
        await store.replace(with: configuration, source: "AIKitView")
        recentChanges = await store.recentChanges(limit: 6)
        status = "Applied"
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
    AIKitView()
}
