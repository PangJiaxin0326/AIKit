import Foundation
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

private func aiKitText(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: .module)
}

private struct AIKitStreamingTextAccumulator {
    private var renderedText = ""
    private var pendingChunks: [String] = []
    private var pendingBytes = 0
    private let flushThreshold = 512

    var isEmpty: Bool { renderedText.isEmpty && pendingChunks.isEmpty }

    mutating func append(_ delta: String) -> String? {
        guard !delta.isEmpty else { return nil }
        pendingChunks.append(delta)
        pendingBytes += delta.utf8.count
        guard pendingBytes >= flushThreshold else { return nil }
        return flush()
    }

    mutating func flush() -> String {
        if !pendingChunks.isEmpty {
            renderedText += pendingChunks.joined()
            pendingChunks.removeAll(keepingCapacity: true)
        }
        pendingBytes = 0
        return renderedText
    }
}

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

    /// Maps a turn error to a user-facing string. `nonisolated` so the
    /// voice mode can reuse it off the main actor.
    nonisolated static func describe(_ error: any Error) -> String {
        if let violation = error as? GuardrailViolation {
            return AIKitUILocalization.string(
                "Blocked by \(violation.railID) at \(violation.stage.rawValue): \(violation.reason)"
            )
        }
        if let iteration = error as? IterationLimitExceeded {
            return AIKitUILocalization.string(
                "Stopped after reaching the \(iteration.limit)-iteration limit."
            )
        }
        if let deadline = error as? TurnDeadlineExceeded {
            return AIKitUILocalization.string(
                "Stopped after exceeding the \(Int(deadline.budget))s turn budget."
            )
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
        var streamingBuffer = AIKitStreamingTextAccumulator()
        var reasoningBuffer = AIKitStreamingTextAccumulator()

        // Surface whatever is still buffered before recording a terminal
        // line, so a sub-flush-threshold tail isn't dropped when the turn ends.
        func flushStreamingBuffers() {
            if !streamingBuffer.isEmpty {
                streamingText = streamingBuffer.flush()
            }
            if !reasoningBuffer.isEmpty {
                reasoningText = reasoningBuffer.flush()
            }
        }

        do {
            for try await event in await orchestrator.run(trimmed) {
                switch event {
                case .llmDelta(let delta):
                    if let text = streamingBuffer.append(delta) {
                        streamingText = text
                    }
                case .reasoningDelta(let delta):
                    if let text = reasoningBuffer.append(delta) {
                        reasoningText = text
                    }
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
                    flushStreamingBuffers()
                    lines.append(Line(role: "assistant", text: text))
                    streamingText = ""
                    reasoningText = ""
                case .failure(let reason):
                    flushStreamingBuffers()
                    lastError = reason
                    lines.append(Line(role: "failed", text: reason))
                    streamingText = ""
                    reasoningText = ""
                case .error(let error):
                    flushStreamingBuffers()
                    let message = Self.describe(error)
                    lastError = message
                    lines.append(Line(role: "error", text: message))
                case .promptBuilt:
                    break
                }
            }
        } catch {
            flushStreamingBuffers()
            let message = Self.describe(error)
            lastError = message
            lines.append(Line(role: "error", text: message))
        }
        isRunning = false
    }
}

@MainActor
@Observable
private final class AssistantInputCoordinator {
    var session: AIKitSession
    var voiceInput = AssistantVoiceInputController()
    var text = ""

    @ObservationIgnored private let orchestrator: Orchestrator
    @ObservationIgnored private var lastInstruction = ""

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
        self.session = AIKitSession(orchestrator: orchestrator)
    }

    func sendCurrentText(activity: OrchestratorActivity) {
        sendText(text, activity: activity)
    }

    func sendText(_ rawText: String, activity: OrchestratorActivity) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !activity.isBusy else { return }
        text = ""
        let instruction = activity.hasFailed
            ? aiKitContextualFollowUpInstruction(
                previous: lastInstruction,
                reason: activity.failureReason,
                followUp: trimmed
            )
            : trimmed
        lastInstruction = trimmed
        Task { await session.send(instruction) }
    }

    func startVoiceRecording(activity: OrchestratorActivity) {
        guard !activity.isBusy, !voiceInput.isVoiceTranscribing else { return }
        text = ""
        voiceInput.startRecording()
    }

    func finishVoiceRecording(activity: OrchestratorActivity) {
        voiceInput.finishRecording { [weak self] text in
            self?.sendText(text, activity: activity)
        }
    }

    func cancelVoiceInput() {
        voiceInput.cancel()
    }

    func clearVoiceError() {
        voiceInput.clearError()
    }

    func cancelCurrentWork() {
        Task { await orchestrator.cancelActiveTurns() }
    }

    func dismissFailure() {
        Task { await orchestrator.cancelActiveTurns() }
    }
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

#if os(iOS)
/// A tab item that can participate in AIKit's tab-bar assistant entry.
public protocol AIKitChatbotTab: Hashable, CaseIterable, Identifiable, CustomStringConvertible, Sendable {
    static var `default`: Self { get }
    var symbol: String { get }
}

/// TabView wrapper with an AI assistant bottom accessory and a FAB panel.
///
/// The bottom accessory mirrors the expanded pet input surface: text entry,
/// voice recording, live busy state, cancellation, and failure follow-up all
/// use the same controls. The FAB panel shows app-provided content for the
/// selected tab, plus a button that switches to AIKit's memory/tools/activity
/// detail surface without a prompt field.
public struct AIKitChatbotTabBar<Item: AIKitChatbotTab, TabContent: View, TabFabContent: View>: View {
    @Binding private var activeTab: Item?
    @State private var isFABExpanded = false
    @State private var showsRuntimeDetails = false
    @State private var selectedMenu = ChatbotMenu.context
    @State private var activityDisplay: OverlayActivityDisplay = .tasks
    @State private var snapshot: OrchestratorSnapshot?
    @State private var activity: OrchestratorActivity = .idle
    @State private var lastActiveTab: Item = Item.default
    /// Backs the TabView's selection and is never `.none`, so the TabView never
    /// selects/restores the empty search tab — that empty-tab churn is what
    /// corrupts the hosted NavigationStack on device. `activeTab` (the external
    /// binding) is only updated for real tabs.
    @State private var selectedTab: Item = Item.default

    private let orchestrator: Orchestrator
    private let viewContext: @Sendable (Item) -> ViewContext
    private let tabContent: @MainActor (Item) -> TabContent
    private let tabFabContent: @MainActor (AIKitOverlayContext, Item) -> TabFabContent

    @MainActor
    public init(
        selection activeTab: Binding<Item?>,
        orchestrator: Orchestrator,
        viewContext: @escaping @Sendable (Item) -> ViewContext,
        @ViewBuilder tabContent: @escaping @MainActor (Item) -> TabContent,
        @ViewBuilder tabFabContent: @escaping @MainActor (AIKitOverlayContext, Item) -> TabFabContent
    ) {
        self._activeTab = activeTab
        self.orchestrator = orchestrator
        self.viewContext = viewContext
        self.tabContent = tabContent
        self.tabFabContent = tabFabContent
    }

    public var body: some View {
        TabView(selection: tabSelection) {
            ForEach(Array(Item.allCases), id: \.description) { tab in
                Tab(tab.description, systemImage: tab.symbol, value: tab) {
                    tabContent(tab)
                        // Tapping anywhere in the tab content resigns the
                        // accessory text field so the keyboard drops away.
                        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                        .aiKitActiveContext(selectedTab == tab ? viewContext(tab) : nil)
                        .aiKitTabFabOverlay(isPresented: isFABExpanded) {
                            AIKitTabFabPanel(
                                context: overlayContext(for: tab),
                                snapshot: snapshot,
                                activity: activity,
                                selectedMenu: $selectedMenu,
                                activityDisplay: $activityDisplay,
                                showsRuntimeDetails: $showsRuntimeDetails
                            ) {
                                tabFabContent(overlayContext(for: tab), tab)
                            }
                        } onDismiss: {
                            dismissFAB()
                        }
                }
            }

            Tab(value: .none, role: .search) {
                // The selection wrapper refuses this tab, but SwiftUI still
                // renders its content for one frame on tap. An EmptyView paints
                // that frame white — a visible flash in the content area. Fill
                // it with the grouped background so the flash blends in.
                Color(.systemGroupedBackground).ignoresSafeArea()
            } label: {
                Image(systemName: "sparkles")
            }
        }
        .background {
            AIKitSearchTabSelectionInterceptor(
                onTapSearchTab: { toggleFABPanel() }
            )
            .frame(width: 0, height: 0)
        }
        .tabViewBottomAccessory {
            AssistantTabBottomAccessory(orchestrator: orchestrator)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // External (e.g. AI-driven) navigation sets `activeTab`; mirror it into
        // the TabView's `selectedTab` storage. The reverse direction (user taps)
        // flows through `tabSelection`'s setter.
        .onChange(of: activeTab) { _, newValue in
            if let newValue, newValue != selectedTab {
                selectedTab = newValue
                lastActiveTab = newValue
            }
        }
        .onChange(of: selectedMenu) { _, menu in
            if menu != .activity { activityDisplay = .tasks }
        }
        .task {
            if let tab = activeTab {
                if tab != selectedTab { selectedTab = tab }
            } else {
                activeTab = selectedTab
            }
            await refreshSnapshot()
        }
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

    /// Wraps the TabView selection. The getter always returns a real tab
    /// (`selectedTab`), so the TabView never selects the empty search tab. The
    /// setter updates the selection for real tabs and intercepts the search
    /// tab's `.none` value to toggle the assistant panel instead.
    private var tabSelection: Binding<Item?> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard let newValue else {
                    Task { @MainActor in toggleFABPanel() }
                    return
                }
                selectedTab = newValue
                lastActiveTab = newValue
                if activeTab != newValue { activeTab = newValue }
                showsRuntimeDetails = false
            }
        )
    }

    @MainActor
    private func toggleFABPanel() {
        showsRuntimeDetails = false
        isFABExpanded.toggle()
        Task { await refreshSnapshot() }
    }

    private func dismissFAB() {
        showsRuntimeDetails = false
        isFABExpanded = false
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func overlayContext(for tab: Item) -> AIKitOverlayContext {
        AIKitOverlayContext(currentViewContext: viewContext(tab), snapshot: snapshot)
    }

    private func refreshSnapshot() async {
        snapshot = await orchestrator.snapshot(recentActivityLimit: 24, recentTaskLimit: 8)
    }
}

private struct AIKitSearchTabSelectionInterceptor: UIViewControllerRepresentable {
    let onTapSearchTab: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onTapSearchTab = onTapSearchTab
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onTapSearchTab = onTapSearchTab
        controller.scheduleInterceptorInstall()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onTapSearchTab: (@MainActor () -> Void)?

        private lazy var searchTapRecognizer: SearchTabTapGestureRecognizer = {
            let recognizer = SearchTabTapGestureRecognizer(
                target: self,
                action: #selector(handleSearchTap(_:))
            )
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = true
            recognizer.delegate = self
            return recognizer
        }()

        private weak var installedTabBar: UITabBar?
        private weak var searchAuxiliaryView: UIView?
        private var installTask: Task<Void, Never>?

        private static let searchAuxiliaryClassNameFragment = "UITabBarAuxiliaryView"
        private static let maxInstallAttempts = 20
        private static let installRetryDelay: Duration = .milliseconds(50)

        deinit {
            installTask?.cancel()
            MainActor.assumeIsolated {
                removeInterceptor()
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            scheduleInterceptorInstall()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleInterceptorInstall()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installInterceptorIfPossible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            installTask?.cancel()
            removeInterceptor()
        }

        @MainActor
        func scheduleInterceptorInstall() {
            installTask?.cancel()
            installTask = Task { @MainActor [weak self] in
                for _ in 0..<Self.maxInstallAttempts {
                    guard let self else { return }
                    if installInterceptorIfPossible() {
                        return
                    }
                    try? await Task.sleep(for: Self.installRetryDelay)
                }
            }
        }

        @MainActor
        @discardableResult
        private func installInterceptorIfPossible() -> Bool {
            guard let window = view.window,
                  let tabBar = findTabBar(in: window)
            else {
                removeInterceptor()
                return false
            }

            if installedTabBar !== tabBar {
                removeInterceptor()
                tabBar.addGestureRecognizer(searchTapRecognizer)
                installedTabBar = tabBar
            }

            guard let auxiliaryView = findSearchAuxiliaryView(in: tabBar) else {
                searchAuxiliaryView = nil
                searchTapRecognizer.isEnabled = true
                return false
            }

            searchAuxiliaryView = auxiliaryView
            searchTapRecognizer.isEnabled = auxiliaryView.isHidden == false
                && auxiliaryView.alpha > 0.01
                && auxiliaryView.bounds.isEmpty == false
            return true
        }

        @MainActor
        private func removeInterceptor() {
            installedTabBar?.removeGestureRecognizer(searchTapRecognizer)
            installedTabBar = nil
            searchAuxiliaryView = nil
        }

        @objc private func handleSearchTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .recognized else { return }
            onTapSearchTab?()
        }

        @MainActor
        private func findTabBar(in root: UIView) -> UITabBar? {
            if let tabBar = root as? UITabBar {
                return tabBar
            }

            for subview in root.subviews {
                if let tabBar = findTabBar(in: subview) {
                    return tabBar
                }
            }

            return nil
        }

        @MainActor
        private func findSearchAuxiliaryView(in tabBar: UITabBar) -> UIView? {
            tabBar.subviews
                .filter { view in
                    isSearchAuxiliaryView(view) && view.bounds.isEmpty == false
                }
                .max { lhs, rhs in lhs.frame.maxX < rhs.frame.maxX }
        }

        private func isSearchAuxiliaryView(_ view: UIView) -> Bool {
            NSStringFromClass(type(of: view))
                .contains(Self.searchAuxiliaryClassNameFragment)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard
                gestureRecognizer === searchTapRecognizer,
                let tabBar = installedTabBar,
                let auxiliaryView = searchAuxiliaryView,
                auxiliaryView.isHidden == false,
                auxiliaryView.alpha > 0.01,
                auxiliaryView.bounds.isEmpty == false
            else {
                return false
            }

            let searchHitFrame = auxiliaryView.frame.insetBy(dx: -8, dy: -8)
            return searchHitFrame.contains(touch.location(in: tabBar))
        }
    }

    final class SearchTabTapGestureRecognizer: UITapGestureRecognizer {
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

/// A SwiftUI state-management surface for AIKit's Core, Capability, Runtime,
/// and Safety configuration.
public struct AIKitView: View {
    @State private var model: AIKitConfigurationViewModel
    @State private var providerCredentials: AIKitProviderCredentialStore

    private let orchestrator: Orchestrator?

    @MainActor
    public init(
        configurationStore: AIKitConfigurationStore = AIKitConfigurationStore(),
        tools: [any Tool] = []
    ) {
        self.orchestrator = nil
        _model = State(initialValue: AIKitConfigurationViewModel(
            store: configurationStore,
            tools: tools
        ))
        _providerCredentials = State(initialValue: AIKitProviderCredentialStore.load())
    }

    @MainActor
    public init(
        orchestrator: Orchestrator,
        configurationStore: AIKitConfigurationStore = AIKitConfigurationStore(),
        tools: [any Tool] = []
    ) {
        self.orchestrator = orchestrator
        _model = State(initialValue: AIKitConfigurationViewModel(
            store: configurationStore,
            tools: tools
        ))
        _providerCredentials = State(initialValue: AIKitProviderCredentialStore.load())
    }

    @ViewBuilder
    public var body: some View {
        dashboard
            .task { await model.load() }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AIKitMetrics.sectionSpacing) {
                header
                VStack(spacing: 12) {
                    coreSection
                    capabilitySection
                    runtimeSection
                    safetySection
                }
                if !model.recentChanges.isEmpty {
                    changeLogSection
                }
                resetFooter
            }
            .padding(.horizontal, AIKitMetrics.pagePadding)
            .padding(.vertical, 28)
            .frame(maxWidth: AIKitMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: model.recentChanges.count)
        }
        .scrollIndicators(.hidden)
        .background {
            dashboardBackground
        }
    }

    private var dashboardBackground: some View {
        ZStack {
            Rectangle()
                .fill(.background)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.07),
                    Color.clear,
                    Color.primary.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    headerTitle
                    Spacer(minLength: 16)
                    statusBadge
                }
                VStack(alignment: .leading, spacing: 12) {
                    headerTitle
                    statusBadge
                }
            }
            summaryStrip
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.2), value: model.status)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            aiKitText("AIKit")
                .font(.largeTitle)
                .bold()
            aiKitText("Core · Capability · Runtime · Safety")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusBadge: some View {
        let tint: Color = model.status == AIKitUILocalization.string("Reset") ? .orange : .green
        return HStack(spacing: 7) {
            Image(systemName: model.status == nil ? "circle.fill" : "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(tint)
            Group {
                if let status = model.status {
                    Text(status)
                } else {
                    aiKitText("Ready")
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var summaryStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    providerPickerCapsule
                    modelPickerCapsule
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    providerPickerCapsule
                    modelPickerCapsule
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                AIKitSummaryChip(
                    title: "Tools",
                    value: "\(model.configuration.capability.enabledToolNames.count)",
                    systemImage: "wrench.and.screwdriver",
                    tint: .purple
                )
                AIKitSummaryChip(
                    title: "Guardrails",
                    value: "\(model.configuration.safety.enabledGuardrailIDs.count)",
                    systemImage: "shield.checkered",
                    tint: .green
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerPickerCapsule: some View {
        HStack {
            Menu {
                ForEach(AIKitProviderDefinition.all) { provider in
                    Button(provider.displayName) {
                        model.selectProvider(provider.kind)
                    }
                }
            } label: {
                AIKitPickerCapsuleLabel(
                    title: "Provider",
                    value: selectedProviderDefinition.displayName,
                    systemImage: "server.rack",
                    tint: .blue
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 150, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var modelPickerCapsule: some View {
        let modelOptions = model.modelOptions(for: selectedProvider)
        let isRefreshingModels = model.isRefreshingModels(for: selectedProvider)

        return HStack(spacing: 8) {
            Menu {
                Button {
                    model.selectModel(nil, for: selectedProvider)
                } label: {
                    aiKitText("None")
                }
                Divider()
                ForEach(modelOptions, id: \.self) { modelName in
                    Button(modelName) {
                        model.selectModel(modelName, for: selectedProvider)
                    }
                }
            } label: {
                AIKitPickerCapsuleLabel(
                    title: "Model",
                    value: selectedModelTitle,
                    systemImage: "cpu",
                    tint: .indigo
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)

            if selectedProviderDefinition.supportsModelCatalogRefresh {
                Button {
                    Task { await refreshModelCatalog() }
                } label: {
                    ZStack {
                        Label {
                            aiKitText("Refresh models")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                            .font(.footnote)
                            .opacity(isRefreshingModels ? 0 : 1)
                        if isRefreshingModels {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .glassEffect(
                        .regular.interactive().tint(Color.indigo.opacity(0.08)),
                        in: .circle
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingModels)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(Color.indigo.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var coreSection: some View {
        AIKitConfigurationSection(title: "Core", systemImage: "cpu", tint: .blue) {
            providerCredentialRow

            if let modelCatalogStatus = model.modelCatalogStatus(for: selectedProvider) {
                Label(
                    modelCatalogStatus,
                    systemImage: model.modelCatalogStatusIsError(for: selectedProvider)
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                    .font(.footnote)
                    .foregroundStyle(
                        model.modelCatalogStatusIsError(for: selectedProvider) ? .red : .secondary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aiKitContainerStyle()
            }

            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Seconds"),
                    text: optionalNumberBinding(\.core.timeout),
                    prompt: aiKitText("Seconds")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Timeout")
            }
            .aiKitTextFieldRowStyle()
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Default"),
                    text: optionalNumberBinding(\.core.temperature),
                    prompt: aiKitText("Default")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Temperature")
            }
            .aiKitTextFieldRowStyle()
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Default"),
                    text: optionalNumberBinding(\.core.maxTokens),
                    prompt: aiKitText("Default")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Max tokens")
            }
            .aiKitTextFieldRowStyle()
        }
    }

    @ViewBuilder
    private var providerCredentialRow: some View {
        if selectedProviderDefinition.apiKeyStrategy.requiresCredential {
            LabeledContent {
                SecureField(
                    AIKitUILocalization.string("API key"),
                    text: providerAPIKeyBinding,
                    prompt: aiKitText("API key")
                )
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .textContentType(.password)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("API key")
            }
            .aiKitTextFieldRowStyle()
        }
    }

    private var capabilitySection: some View {
        AIKitConfigurationSection(title: "Capability", systemImage: "slider.horizontal.3", tint: .purple) {
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Display name"),
                    text: binding(\.capability.contextDisplayName),
                    prompt: aiKitText("Display name")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Context")
            }
            .aiKitTextFieldRowStyle()
            VStack(alignment: .leading, spacing: 8) {
                aiKitText("System prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: binding(\.capability.systemPromptFragment))
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 92)
                    .aiKitContainerStyle()
            }
            LabeledContent {
                Stepper(
                    "\(model.configuration.capability.memoryLimit)",
                    value: binding(\.capability.memoryLimit),
                    in: 0...500
                )
            } label: {
                aiKitText("Memory window")
            }
            if model.availableTools.isEmpty {
                LabeledContent {
                    TextField(
                        AIKitUILocalization.string("Comma-separated"),
                        text: setBinding(\.capability.enabledToolNames),
                        prompt: aiKitText("Comma-separated")
                    )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
                } label: {
                    aiKitText("Enabled tools")
                }
                .aiKitTextFieldRowStyle()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    aiKitText("Enabled tools")
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
        AIKitConfigurationSection(title: "Runtime", systemImage: "point.3.connected.trianglepath.dotted", tint: .teal) {
            Toggle(isOn: binding(\.runtime.streamsResponses)) {
                aiKitText("Stream responses")
            }
            LabeledContent {
                Stepper(
                    "\(model.configuration.runtime.maxIterations)",
                    value: binding(\.runtime.maxIterations),
                    in: 1...50
                )
            } label: {
                aiKitText("Max iterations")
            }
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Seconds"),
                    text: optionalNumberBinding(\.runtime.maxTurnDuration),
                    prompt: aiKitText("Seconds")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Turn budget")
            }
            .aiKitTextFieldRowStyle()
            Picker(selection: binding(\.runtime.toolCallFallback)) {
                ForEach(AIKitConfiguration.ToolCallFallbackMode.allCases, id: \.self) { mode in
                    Text(mode.localizedLabel, bundle: .module).tag(mode)
                }
            } label: {
                aiKitText("Tool fallback")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: binding(\.runtime.workflowPlanning)) {
                aiKitText("Workflow planning")
            }
            Toggle(isOn: binding(\.runtime.twoRoundAutoBind)) {
                aiKitText("Two-round auto-bind")
            }
            Toggle(isOn: binding(\.runtime.twoRoundStructuredPlannerOutput)) {
                aiKitText("Structured planner output")
            }
        }
    }

    private var safetySection: some View {
        AIKitConfigurationSection(title: "Safety", systemImage: "shield.lefthalf.filled", tint: .green) {
            Toggle(isOn: binding(\.safety.piiRedactionEnabled)) {
                aiKitText("PII redaction")
            }
            Toggle(isOn: binding(\.safety.injectionSniffingEnabled)) {
                aiKitText("Injection sniffing")
            }
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Characters"),
                    text: optionalNumberBinding(\.safety.outputLengthLimit),
                    prompt: aiKitText("Characters")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Output cap")
            }
            .aiKitTextFieldRowStyle()
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Comma-separated"),
                    text: setBinding(\.safety.enabledGuardrailIDs),
                    prompt: aiKitText("Comma-separated")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Guardrails")
            }
            .aiKitTextFieldRowStyle()
            LabeledContent {
                TextField(
                    AIKitUILocalization.string("Comma-separated"),
                    text: setBinding(\.safety.allowlistedToolNames),
                    prompt: aiKitText("Comma-separated")
                )
                    .multilineTextAlignment(.trailing)
                    .aiKitFieldStyle()
            } label: {
                aiKitText("Tool allowlist")
            }
            .aiKitTextFieldRowStyle()
        }
    }

    private var changeLogSection: some View {
        AIKitConfigurationSection(
            title: "Configuration Activity",
            systemImage: "clock.arrow.circlepath",
            tint: .gray
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.recentChanges) { change in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(.tertiary)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.title)
                                .font(.subheadline)
                            Text(change.valueDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var resetFooter: some View {
        GlassEffectContainer(spacing: 10) {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    model.resetToDefaults()
                } label: {
                    Label {
                        aiKitText("Reset to defaults")
                    } icon: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                        .font(.callout)
                }
                .buttonStyle(.glass)
                .tint(.red)
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    private var selectedProvider: AIKitProviderKind {
        model.selectedProvider
    }

    private var selectedProviderDefinition: AIKitProviderDefinition {
        selectedProvider.definition
    }

    private var selectedModelTitle: String {
        model.configuration.core
            .providerConfiguration(for: selectedProvider)
            .defaultModel ?? "None"
    }

    private var providerAPIKeyBinding: Binding<String> {
        Binding(
            get: { providerCredentials.apiKey(for: selectedProvider) },
            set: { newValue in
                providerCredentials.setAPIKey(newValue, for: selectedProvider)
                providerCredentials.save()
            }
        )
    }

    private var providerAPIKey: String {
        providerCredentials.apiKey(for: selectedProvider)
    }

    private func refreshModelCatalog() async {
        await model.refreshModels(
            provider: selectedProvider,
            apiKey: providerAPIKey
        )
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { model.update(keyPath, to: $0) }
        )
    }

    /// A text binding for an optional numeric config field: shows the value's
    /// string form (empty when unset) and writes back the parsed value, or
    /// `nil` when the text doesn't parse (empty field ⇒ "use the default").
    private func optionalNumberBinding<Value: LosslessStringConvertible>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value?>
    ) -> Binding<String> {
        Binding(
            get: { model.configuration[keyPath: keyPath]?.description ?? "" },
            set: { model.update(keyPath, to: Value($0)) }
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

/// The text-first ("assistant") pet button: a tap-to-expand glass capsule
/// with a prompt field, voice input, and a long-press detail panel. Reached
/// through `AIKitChatbotOverlay` with `mode: .assistant`.
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
    func aiChatbotOverlay(
        orchestrator: Orchestrator,
        mode: AIKitChatbotOverlayMode = .assistant
    ) -> some View {
        overlay {
            AIKitChatbotOverlay(orchestrator: orchestrator, mode: mode)
        }
    }

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

@MainActor
@Observable
private final class AIKitConfigurationViewModel {
    private struct ModelCatalogState {
        var status: String?
        var statusIsError = false
        var isRefreshing = false
    }

    var configuration: AIKitConfiguration
    var availableTools: [ToolDescriptor] = []
    var recentChanges: [AIKitConfigurationChange] = []
    var status: String?

    private let store: AIKitConfigurationStore
    private let tools: [any Tool]
    private let modelCatalog: AIKitModelCatalog
    private var modelCatalogStates: [AIKitProviderKind: ModelCatalogState] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(
        store: AIKitConfigurationStore,
        tools: [any Tool],
        modelCatalog: AIKitModelCatalog = AIKitModelCatalog()
    ) {
        self.store = store
        self.tools = tools
        self.modelCatalog = modelCatalog
        self.configuration = .standard
    }

    var selectedProvider: AIKitProviderKind {
        configuration.core.activeProvider
    }

    func load() async {
        configuration = await store.snapshot()
        recentChanges = await store.recentChanges(limit: 6)
        availableTools = tools
            .map(\.descriptor)
            .sorted { $0.name < $1.name }
        status = nil
    }

    func modelOptions(for provider: AIKitProviderKind) -> [String] {
        let configuredModels = configuration.core.providerConfiguration(for: provider).availableModels
        return configuredModels.isEmpty ? provider.definition.staticModelIDs : configuredModels
    }

    func modelCatalogStatus(for provider: AIKitProviderKind) -> String? {
        modelCatalogStates[provider]?.status
    }

    func modelCatalogStatusIsError(for provider: AIKitProviderKind) -> Bool {
        modelCatalogStates[provider]?.statusIsError ?? false
    }

    func isRefreshingModels(for provider: AIKitProviderKind) -> Bool {
        modelCatalogStates[provider]?.isRefreshing ?? false
    }

    func selectProvider(_ provider: AIKitProviderKind) {
        configuration.core.activeProvider = provider
        saveCurrentConfiguration(status: "Saved")
    }

    func selectModel(_ model: String?, for provider: AIKitProviderKind) {
        var providerConfiguration = configuration.core.providerConfiguration(for: provider)
        providerConfiguration.defaultModel = model?.emptyAsNil
        configuration.core.setProviderConfiguration(providerConfiguration, for: provider)
        saveCurrentConfiguration(status: "Saved")
    }

    func selectEndpointURL(_ endpointURL: String?, for provider: AIKitProviderKind) {
        var providerConfiguration = configuration.core.providerConfiguration(for: provider)
        providerConfiguration.endpointURL = endpointURL?.emptyAsNil
        configuration.core.setProviderConfiguration(providerConfiguration, for: provider)
        saveCurrentConfiguration(status: "Saved")
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
        modelCatalogStates = [:]
        saveCurrentConfiguration(status: "Reset")
    }

    func refreshModels(
        provider: AIKitProviderKind,
        apiKey: String
    ) async {
        guard !isRefreshingModels(for: provider) else { return }
        updateModelCatalogState(provider) { state in
            state.isRefreshing = true
            state.status = nil
            state.statusIsError = false
        }
        defer {
            updateModelCatalogState(provider) { state in
                state.isRefreshing = false
            }
        }

        do {
            let models = try await modelCatalog.fetchModels(
                for: provider,
                apiKey: apiKey,
                timeout: configuration.core.timeout
            )
            updateModelCatalogState(provider) { state in
                state.status = models.isEmpty
                    ? AIKitUILocalization.string("No models returned.")
                    : AIKitUILocalization.string("Loaded \(models.count) models.")
                state.statusIsError = false
            }
            var providerConfiguration = configuration.core.providerConfiguration(for: provider)
            providerConfiguration.replaceAvailableModels(models)
            configuration.core.setProviderConfiguration(providerConfiguration, for: provider)
            saveCurrentConfiguration(status: "Saved")
        } catch {
            updateModelCatalogState(provider) { state in
                state.status = error.localizedDescription
                state.statusIsError = true
            }
        }
    }

    private func updateModelCatalogState(
        _ provider: AIKitProviderKind,
        _ update: (inout ModelCatalogState) -> Void
    ) {
        var state = modelCatalogStates[provider] ?? ModelCatalogState()
        update(&state)
        modelCatalogStates[provider] = state
    }

    private func saveCurrentConfiguration(status: String.LocalizationValue) {
        saveTask?.cancel()

        let configuration = configuration
        saveTask = Task { [store, configuration] in
            guard !Task.isCancelled else { return }
            await store.replace(with: configuration, source: "AIKitView")
            guard !Task.isCancelled else { return }

            let recentChanges = await store.recentChanges(limit: 6)
            guard !Task.isCancelled else { return }

            self.recentChanges = recentChanges
            self.status = AIKitUILocalization.string(status)
        }
    }

    deinit {
        saveTask?.cancel()
    }
}

private struct AIKitConfigurationSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AIKitMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AIKitMetrics.rowSpacing) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AIKitMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .overlay {
            shape.strokeBorder(.separator.opacity(0.38), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: AIKitMetrics.badgeSize, height: AIKitMetrics.badgeSize)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: AIKitMetrics.badgeRadius))
            aiKitText(title)
                .font(.headline)
                .bold()
            Spacer(minLength: 0)
        }
    }
}

private struct AIKitTextFieldRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                configuration.label
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: AIKitMetrics.textFieldRowSpacer)
                configuration.content
            }

            VStack(alignment: .leading, spacing: AIKitMetrics.textFieldStackSpacing) {
                configuration.label
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AIKitSummaryChip: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                aiKitText(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 150, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        }
    }
}

private struct AIKitPickerCapsule: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        AIKitPickerCapsuleLabel(
            title: title,
            value: value,
            systemImage: systemImage,
            tint: tint
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 150, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        }
    }
}

private struct AIKitPickerCapsuleLabel: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                aiKitText(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, alignment: .leading)
        }
    }
}

#if os(iOS)
private struct AIKitTabFabPanel<CustomContent: View>: View {
    let context: AIKitOverlayContext
    let snapshot: OrchestratorSnapshot?
    let activity: OrchestratorActivity
    @Binding var selectedMenu: ChatbotMenu
    @Binding var activityDisplay: OverlayActivityDisplay
    @Binding var showsRuntimeDetails: Bool

    private let customContent: () -> CustomContent

    /// The two heights the panel toggles between when its free space is
    /// tapped. It opens at the smaller size. (Computed rather than stored
    /// because `AIKitTabFabPanel` is generic.)
    private static var collapsedHeight: CGFloat { 300 }
    private static var expandedHeight: CGFloat { 500 }

    @State private var panelHeight: CGFloat = Self.collapsedHeight
    /// Tracks the software keyboard so the first free-space tap dismisses it
    /// rather than resizing the panel.
    @State private var keyboardVisible = false

    init(
        context: AIKitOverlayContext,
        snapshot: OrchestratorSnapshot?,
        activity: OrchestratorActivity,
        selectedMenu: Binding<ChatbotMenu>,
        activityDisplay: Binding<OverlayActivityDisplay>,
        showsRuntimeDetails: Binding<Bool>,
        @ViewBuilder customContent: @escaping () -> CustomContent
    ) {
        self.context = context
        self.snapshot = snapshot
        self.activity = activity
        self._selectedMenu = selectedMenu
        self._activityDisplay = activityDisplay
        self._showsRuntimeDetails = showsRuntimeDetails
        self.customContent = customContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsRuntimeDetails {
                runtimeDetailHeader
                AssistantRuntimeDetailContent(
                    snapshot: snapshot,
                    activity: activity,
                    selectedMenu: $selectedMenu,
                    activityDisplay: $activityDisplay,
                    // Leave room for the panel's padding, header, and the
                    // detail picker so the scroll area fits inside the panel.
                    maxContentHeight: max(0, panelHeight - 110)
                )
            } else {
                customContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Button {
                    withAnimation(.spring(duration: 0.24)) {
                        showsRuntimeDetails = true
                    }
                } label: {
                    Label {
                        aiKitText("AI details")
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: panelHeight, alignment: .top)
        .contentShape(.rect)
        .onTapGesture { handleFreeSpaceTap() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification
        )) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { _ in
            keyboardVisible = false
        }
    }

    /// A tap on the panel's free space toggles its height — but while the
    /// keyboard is up, the first tap only dismisses it, leaving the size
    /// unchanged so the resize doesn't fight the keyboard animation.
    ///
    /// The resize is driven with an explicit `withAnimation` rather than an
    /// `.animation(_:value:)` modifier so the whole transaction animates —
    /// including the glass surface and bottom-pinned frame applied by the
    /// parent overlay modifier, which sit outside this view's subtree.
    private func handleFreeSpaceTap() {
        if keyboardVisible {
            dismissKeyboard()
        } else {
            withAnimation(.smooth) {
                panelHeight = panelHeight == Self.collapsedHeight
                    ? Self.expandedHeight
                    : Self.collapsedHeight
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var runtimeDetailHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.24)) {
                    showsRuntimeDetails = false
                    activityDisplay = .tasks
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(aiKitText("Back"))

            if let displayName = context.currentViewContext?.displayName {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else {
                aiKitText("AI Details")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AssistantTabBottomAccessory: View {
    @State private var input: AssistantInputCoordinator
    @State private var activity: OrchestratorActivity = .idle
    @FocusState private var fieldFocused: Bool

    private let orchestrator: Orchestrator

    @MainActor
    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
        _input = State(initialValue: AssistantInputCoordinator(orchestrator: orchestrator))
    }

    var body: some View {
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
            horizontalPadding: 12,
            onSubmit: sendDraft,
            onStartVoiceRecording: startVoiceRecording,
            onFinishVoiceRecording: finishVoiceRecording,
            onCancelCurrentWork: cancelCurrentWork,
            onDismissFailure: dismissFailure,
            onTextChanged: input.clearVoiceError,
            onClearVoiceError: clearVoiceError
        )
        // No background of our own: the system tab accessory already
        // renders the row on its glass surface, so an extra tinted capsule
        // only leaves uncovered gaps around the row.
        .frame(maxWidth: .infinity, minHeight: 44)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task {
            for await update in orchestrator.activityUpdates() {
                activity = update
            }
        }
        .onChange(of: activity.isBusy) { _, busy in
            if !busy && !activity.hasFailed { input.text = "" }
        }
        .onDisappear { cancelVoiceInput() }
    }

    private func sendDraft() {
        input.sendCurrentText(activity: activity)
    }

    private func sendText(_ rawText: String) {
        input.sendText(rawText, activity: activity)
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

    private func dismissFailure() {
        fieldFocused = false
        input.dismissFailure()
    }
}

private struct AIKitTabFabOverlayModifier<ViewContent: View>: ViewModifier {
    var isPresented: Bool
    let viewContent: () -> ViewContent
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                GlassEffectContainer {
                    if isPresented {
                        Rectangle()
                            .fill(.black.opacity(0.25))
                            .contentShape(.rect)
                            .onTapGesture(perform: onDismiss)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }
                    if isPresented {
                        viewContent()
                            .clipShape(.rect(cornerRadius: 30))
                            .contentShape(.rect(cornerRadius: 30))
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.horizontal, 15)
                            .padding(.bottom, 10)
                    }
                }
                .allowsHitTesting(isPresented)
                .animation(
                    .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: 0),
                    value: isPresented
                )
            }
    }
}
#endif

private struct AssistantRuntimeDetailContent: View {
    let snapshot: OrchestratorSnapshot?
    let activity: OrchestratorActivity
    @Binding var selectedMenu: ChatbotMenu
    @Binding var activityDisplay: OverlayActivityDisplay
    let maxContentHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(selection: $selectedMenu) {
                ForEach(ChatbotMenu.allCases) { menu in
                    Text(menu.title, bundle: .module).tag(menu)
                }
            } label: {
                aiKitText("Menu")
            }
            .pickerStyle(.segmented)

            menuContent
        }
        .animation(.snappy(duration: 0.2), value: selectedMenu)
        .animation(.snappy(duration: 0.18), value: activityDisplay)
    }

    @ViewBuilder
    private var menuContent: some View {
        if selectedMenu == .activity {
            activityContent
                .frame(maxHeight: maxContentHeight)
        } else {
            ScrollView {
                switch selectedMenu {
                case .context:
                    memoryContent
                case .tools:
                    toolsContent
                case .activity:
                    activityContent
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxContentHeight)
        }
    }

    private var memoryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot, !snapshot.contexts.isEmpty {
                ForEach(snapshot.contexts) { context in
                    OverlayDetailRow(title: context.displayName) {
                        Text(context.id.rawValue)
                            .monospaced()
                        if !context.systemPromptFragment.isEmpty {
                            Text(context.systemPromptFragment)
                                .lineLimit(3)
                        }
                        if !context.toolNames.isEmpty {
                            Text(context.toolNames.sorted().joined(separator: ", "))
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                OverlayEmptyState(
                    systemImage: "questionmark.bubble",
                    message: "No active memory"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot, !snapshot.availableTools.isEmpty {
                ForEach(snapshot.availableTools) { tool in
                    OverlayDetailRow(title: tool.name) {
                        Text(tool.description)
                            .lineLimit(3)
                    }
                }
            } else {
                OverlayEmptyState(
                    systemImage: "wrench.and.screwdriver",
                    message: "No tools available"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var activityContent: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 10) {
                activityHeader
                OverlayActivityStatsRow(metrics: activityMetrics(now: timeline.date))
                ScrollView {
                    activityRows(now: timeline.date)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var activityHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            if let destination = activityBackDestination {
                Button {
                    activityDisplay = destination
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
            .buttonStyle(.plain)
                .accessibilityLabel(aiKitText("Back"))
            }

            VStack(alignment: .leading, spacing: 3) {
                switch activityDisplay {
                case .tasks:
                    aiKitText("Tasks")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if activityTaskGroups.isEmpty {
                        aiKitText("No recent activity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(
                            localized: "\(activityTaskGroups.count) recent",
                            bundle: .module
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                case .task(let id):
                    if let task = activityTask(id: id) {
                        Text(task.instruction)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        activityStatusText(for: task)
                    } else {
                        aiKitText("Task unavailable")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                case .event(let taskID, let eventID):
                    if let event = activityEvent(taskID: taskID, eventID: eventID) {
                        Text(event.kind.rawDetailTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(event.kind.detailLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        aiKitText("Detail unavailable")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func activityRows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch activityDisplay {
            case .tasks:
                let tasks = activityTaskGroups
                if tasks.isEmpty {
                    OverlayEmptyState(systemImage: "clock", message: "No recent activity")
                } else {
                    ForEach(tasks) { task in
                        Button {
                            activityDisplay = .task(task.id)
                        } label: {
                            OverlayActivityTaskRow(task: task)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .task(let id):
                if let task = activityTask(id: id) {
                    if task.activities.isEmpty {
                        OverlayEmptyState(
                            systemImage: "list.bullet.rectangle",
                            message: "No task details"
                        )
                    } else {
                        ForEach(task.activities) { event in
                            Button {
                                activityDisplay = .event(taskID: task.id, eventID: event.id)
                            } label: {
                                OverlayActivityEventRow(event: event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    OverlayEmptyState(
                        systemImage: "clock.arrow.circlepath",
                        message: "Activity no longer available"
                    )
                }
            case .event(let taskID, let eventID):
                if let event = activityEvent(taskID: taskID, eventID: eventID) {
                    OverlayActivityRawPayload(event: event)
                } else {
                    OverlayEmptyState(
                        systemImage: "doc.text.magnifyingglass",
                        message: "Raw payload no longer available"
                    )
                }
            }
        }
    }

    private var activityTaskGroups: [OrchestratorTaskSnapshot] {
        var seen = Set<Int>()
        var groups: [OrchestratorTaskSnapshot] = []
        for task in activity.activeTasks.sorted(by: { $0.startedAt > $1.startedAt }) {
            if seen.insert(task.id).inserted {
                groups.append(task)
            }
        }
        for task in snapshot?.recentTasks ?? [] {
            if seen.insert(task.id).inserted {
                groups.append(task)
            }
        }
        return groups
    }

    private func activityTask(id: Int) -> OrchestratorTaskSnapshot? {
        activityTaskGroups.first { $0.id == id }
    }

    private func activityEvent(taskID: Int, eventID: UUID) -> UsageEvent? {
        activityTask(id: taskID)?.activities.first { $0.id == eventID }
    }

    private var activityBackDestination: OverlayActivityDisplay? {
        switch activityDisplay {
        case .tasks:
            return nil
        case .task:
            return .tasks
        case .event(let taskID, _):
            return .task(taskID)
        }
    }

    private func activityMetrics(now: Date) -> OverlayActivityMetrics {
        switch activityDisplay {
        case .tasks:
            return activityTaskGroups.reduce(.zero) { partial, task in
                OverlayActivityMetrics(
                    inputTokens: partial.inputTokens + task.usage.inputTokens,
                    outputTokens: partial.outputTokens + task.usage.outputTokens,
                    duration: partial.duration + task.duration(at: now)
                )
            }
        case .task(let id), .event(let id, _):
            guard let task = activityTask(id: id) else { return .zero }
            return OverlayActivityMetrics(
                inputTokens: task.usage.inputTokens,
                outputTokens: task.usage.outputTokens,
                duration: task.duration(at: now)
            )
        }
    }

    @ViewBuilder
    private func activityStatusText(for task: OrchestratorTaskSnapshot) -> some View {
        if let failure = task.failureReason {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if task.isRunning {
            Label(task.phase.activityLabel, systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        } else {
            Text(task.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AssistantInputBar: View {
    @Binding var text: String

    let focused: FocusState<Bool>.Binding
    let activity: OrchestratorActivity
    let voiceLevel: Double
    let isRecording: Bool
    let isVoiceTranscribing: Bool
    let voiceError: String?
    let horizontalPadding: CGFloat
    let onSubmit: () -> Void
    let onStartVoiceRecording: () -> Void
    let onFinishVoiceRecording: () -> Void
    let onCancelCurrentWork: () -> Void
    let onDismissFailure: () -> Void
    let onTextChanged: () -> Void
    let onClearVoiceError: () -> Void

    private var trimmedTextIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            statusField
                .padding(.leading, horizontalPadding)
            actionButton
                .padding(.trailing, horizontalPadding)
        }
    }

    @ViewBuilder
    private var statusField: some View {
        if isRecording {
            VoiceWaveformView(level: voiceLevel)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isVoiceTranscribing {
            statusRow(
                systemImage: nil,
                text: AIKitUILocalization.string("Transcribing"),
                showsProgress: true
            )
        } else if activity.isBusy {
            statusRow(systemImage: nil, text: activity.aiKitLocalizedStatusText, showsProgress: true)
        } else if let voiceError {
            statusRow(
                systemImage: "exclamationmark.triangle.fill",
                text: voiceError,
                showsProgress: false
            )
            .onTapGesture(perform: onClearVoiceError)
        } else {
            TextField(
                activity.hasFailed
                    ? AIKitUILocalization.string("Add a clarification…")
                    : AIKitUILocalization.string("Ask the assistant…"),
                text: $text,
                prompt: activity.hasFailed
                    ? aiKitText("Add a clarification…")
                    : aiKitText("Ask the assistant…"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .focused(focused)
            .multilineTextAlignment(.leading)
            .submitLabel(.send)
            .onSubmit(onSubmit)
            .onChange(of: text) { _, _ in onTextChanged() }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(
        systemImage: String?,
        text: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.red)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRecording {
            Button(action: onFinishVoiceRecording) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Stop recording"))
        } else if isVoiceTranscribing {
            EmptyView()
        } else if activity.isBusy {
            Button(action: onCancelCurrentWork) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Cancel"))
        } else if activity.hasFailed && trimmedTextIsEmpty {
            Button(action: onDismissFailure) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Dismiss"))
        } else if trimmedTextIsEmpty {
            Button(action: onStartVoiceRecording) {
                Image(systemName: "mic.fill")
                    .symbolRenderingMode(.monochrome)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.accentColor)
            .disabled(activity.isBusy || isVoiceTranscribing)
            .accessibilityLabel(aiKitText("Start recording"))
        } else {
            Button(action: onSubmit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Send"))
        }
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
            .accessibilityLabel(aiKitText("Recording voice"))
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

/// One entry in the detail panel's menus: a prominent title tightly paired
/// with its softened detail lines. The clear type contrast — bold primary
/// title over a lighter detail — is what makes each entry read as a heading
/// with its data, rather than a stack of look-alike lines.
private struct OverlayDetailRow<Detail: View>: View {
    let title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                detail
            }
            .font(.footnote)
            // Opaque primary, softened with a flat alpha — *not* the
            // hierarchical `.secondary` tier, whose vibrant blend over the
            // panel's translucent material can wash out to invisibility. This
            // keeps the detail clearly legible while staying subordinate to
            // the title.
            .foregroundStyle(.primary)
            .opacity(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverlayActivityTaskRow: View {
    let task: OrchestratorTaskSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.instruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            Text(task.isRunning ? task.phase.activityLabel : AIKitUILocalization.string("Completed"))
                .font(.caption)
                .foregroundStyle(task.isRunning ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct OverlayActivityEventRow: View {
    let event: UsageEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.kind.detailSystemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.kind.detailLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(event.payloadText)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .opacity(0.75)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(event.kind.detailLabel)
    }
}

private struct OverlayActivityRawPayload: View {
    let event: UsageEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(event.payloadText.isEmpty ? AIKitUILocalization.string("Empty payload") : event.payloadText)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverlayActivityStatsRow: View {
    let metrics: OverlayActivityMetrics

    var body: some View {
        HStack(spacing: 12) {
            OverlayActivityStat(
                systemImage: "arrow.down.to.line.compact",
                title: "In",
                value: "\(metrics.inputTokens)"
            )
            OverlayActivityStat(
                systemImage: "arrow.up.to.line.compact",
                title: "Out",
                value: "\(metrics.outputTokens)"
            )
            OverlayActivityStat(
                systemImage: "timer",
                title: "Time",
                value: formattedActivityDuration(metrics.duration)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverlayActivityStat: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.caption2.weight(.semibold))
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A quiet, centered placeholder for the detail panel's empty menus — a soft
/// glyph over a single line, so an empty state still feels considered.
private struct OverlayEmptyState: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(LocalizedStringKey(message), bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private enum ChatbotMenu: CaseIterable, Identifiable {
    case context
    case tools
    case activity

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .context: "Memory"
        case .tools: "Tools"
        case .activity: "Activity"
        }
    }
}

private enum OverlayActivityDisplay: Hashable {
    case tasks
    case task(Int)
    case event(taskID: Int, eventID: UUID)
}

private struct OverlayActivityMetrics: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var duration: TimeInterval

    static let zero = OverlayActivityMetrics(
        inputTokens: 0, outputTokens: 0, duration: 0
    )
}

private func formattedActivityDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
}

private extension OrchestratorActivity {
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
            }
        }
        if let failureReason {
            return failureReason
        }
        return AIKitUILocalization.string("Idle")
    }
}

private extension OrchestratorPhase {
    var activityLabel: String {
        switch self {
        case .idle: return AIKitUILocalization.string("Idle")
        case .preparing: return AIKitUILocalization.string("Preparing")
        case .thinking: return AIKitUILocalization.string("Thinking")
        case .callingTool(let name): return AIKitUILocalization.string("Calling \(name)")
        case .verifying: return AIKitUILocalization.string("Checking result")
        }
    }
}

private extension UsageEvent.Kind {
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

private extension AIKitConfiguration.ToolCallFallbackMode {
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .automatic: "Auto"
        case .enabled: "On"
        case .disabled: "Off"
        }
    }
}

private extension AIKitConfigurationChange {
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

private extension View {
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
            .containerRelativeFrame(.horizontal) { length, _ in
                length * 0.5
            }
            .aiKitContainerStyle()
    }

    func aiKitTextFieldRowStyle() -> some View {
        labeledContentStyle(AIKitTextFieldRowStyle())
    }

    @ViewBuilder
    func chatbotCapsuleStyle(tint: Color) -> some View {
        glassEffect(.regular.interactive().tint(tint), in: .capsule)
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
    AIKitChatbotOverlay(orchestrator: .init(llm: .init(provider: VolcengineArkProvider(apiKey: "preview", model: "doubao-seed-2-0-lite-260215")), tools: .init(), memory: InMemoryMemoryStore(), contextResolver: .init(), guardrails: .init()))
}
