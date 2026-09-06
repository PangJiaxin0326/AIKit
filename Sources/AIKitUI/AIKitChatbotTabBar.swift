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
    /// Keeps legacy draft input alive across tab selection changes.
    @State private var input: AssistantInputCoordinator?
    /// Only real tab values enter selection; assistant activation is a Button.
    @State private var selectedTab: Item = Item.default

    private let orchestrator: Orchestrator?
    private let conversation: AIKitConversation?
    private let viewContext: @Sendable (Item) -> ViewContext
    private let tabContent: @MainActor (Item) -> TabContent
    private let tabFabContent: @MainActor (AIKitOverlayContext, Item) -> TabFabContent

    @MainActor
    @available(*, deprecated, message: "Use the conversation initializer; legacy runtime UI is removed in the next major release.")
    public init(
        selection activeTab: Binding<Item?>,
        orchestrator: Orchestrator,
        viewContext: @escaping @Sendable (Item) -> ViewContext,
        @ViewBuilder tabContent: @escaping @MainActor (Item) -> TabContent,
        @ViewBuilder tabFabContent: @escaping @MainActor (AIKitOverlayContext, Item) -> TabFabContent
    ) {
        self._activeTab = activeTab
        self.orchestrator = orchestrator
        self.conversation = nil
        self.viewContext = viewContext
        self.tabContent = tabContent
        self.tabFabContent = tabFabContent
        self._input = State(initialValue: AssistantInputCoordinator(orchestrator: orchestrator))
    }

    @MainActor
    public init(
        selection activeTab: Binding<Item?>,
        conversation: AIKitConversation,
        viewContext: @escaping @Sendable (Item) -> ViewContext,
        @ViewBuilder tabContent: @escaping @MainActor (Item) -> TabContent,
        @ViewBuilder tabFabContent: @escaping @MainActor (AIKitOverlayContext, Item) -> TabFabContent
    ) {
        self._activeTab = activeTab
        self.orchestrator = nil
        self.conversation = conversation
        self.viewContext = viewContext
        self.tabContent = tabContent
        self.tabFabContent = tabFabContent
        self._input = State(initialValue: nil)
    }

    @ViewBuilder
    public var body: some View {
        if let conversation {
            TabView(selection: $selectedTab) {
                ForEach(Array(Item.allCases), id: \.description) { tab in
                    Tab(tab.description, systemImage: tab.symbol, value: tab) {
                        tabContent(tab)
                            .aiKitActiveContext(selectedTab == tab ? viewContext(tab) : nil)
                    }
                }
            }
            .tabViewBottomAccessory {
                Button("Assistant", systemImage: "sparkles") { isFABExpanded = true }
                    .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $isFABExpanded) {
                NavigationStack {
                    AIKitConversationView(conversation: conversation)
                        .navigationTitle("Assistant")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isFABExpanded = false }
                            }
                            ToolbarItem(placement: .secondaryAction) {
                                NavigationLink("Details") {
                                    tabFabContent(overlayContext(for: selectedTab), selectedTab)
                                }
                            }
                        }
                }
            }
            .onChange(of: selectedTab) { _, tab in activeTab = tab }
            .onChange(of: activeTab) { _, tab in if let tab { selectedTab = tab } }
            .onAppear { selectedTab = activeTab ?? Item.default }
        } else if let orchestrator, let input {
            legacyBody(orchestrator: orchestrator, input: input)
        }
    }

    private func legacyBody(orchestrator: Orchestrator, input: AssistantInputCoordinator) -> some View {

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

        }
        .tabViewBottomAccessory {
            HStack {
                AssistantTabBottomAccessory(input: input, activity: activity)
                Button("Assistant details", systemImage: "sparkles", action: toggleFABPanel)
                    .labelStyle(.iconOnly)
                    .padding(.trailing)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // External (e.g. AI-driven) navigation sets `activeTab`; mirror it into
        // the TabView's `selectedTab` storage. The reverse direction (user taps)
        // flows through `tabSelection`'s setter. The mirror write is deferred
        // one hop: we're mid-update here. The selection write happens before the
        // resign (see the setter) and the remaining side effects ride
        // `onChange(of: selectedTab)`, so this only has to adopt the new tab.
        .onChange(of: activeTab) { _, newValue in
            guard let newValue, newValue != selectedTab else { return }
            Task { @MainActor in
                selectedTab = newValue
                dismissKeyboard()
            }
        }
        // The single home for selection side effects: mirroring back to the
        // external binding, collapsing the runtime-detail surface, and pulling
        // a fresh snapshot for the new tab's active context. Running them here —
        // after the selection commits, in their own transaction — rather than
        // inside the binding setter keeps extra writes from fighting the
        // TabView's selection animation, and the refresh stops the AI-details
        // surface from lagging a tab behind. Fires for both user taps and
        // external navigation; the guard keeps the `activeTab` mirror loop-free.
        .onChange(of: selectedTab) { _, newTab in
            if activeTab != newTab { activeTab = newTab }
            showsRuntimeDetails = false
            Task { await refreshSnapshot() }
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
                if !activity.hasFailed { input.text = "" }
                Task { await refreshSnapshot() }
            }
        }
    }

    /// Commit selection before dismissing the accessory keyboard.
    private var tabSelection: Binding<Item> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                selectedTab = newValue
                dismissKeyboard()
            }
        )
    }

    @MainActor
    private func toggleFABPanel() {
        dismissKeyboard()
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
        snapshot = await orchestrator?.snapshot(recentActivityLimit: 24, recentTaskLimit: 8)
    }
}


#endif

#if os(iOS)
struct AIKitTabFabPanel<CustomContent: View>: View {
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
    @State private var keyboardObservers: [NotificationCenter.ObservationToken] = []
    /// The sticky failure the user dismissed in place. Dismissal is local to
    /// the panel — the orchestrator keeps the sticky reason so the input bar
    /// can still build a clarification follow-up — and is forgotten when a
    /// new run clears the sticky reason.
    @State private var dismissedFailureReason: String?

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
        // After the tap gesture, so the failure surface absorbs taps instead
        // of resizing the panel beneath it.
        .overlay {
            if let reason = visibleFailureReason {
                failureOverlay(reason)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: visibleFailureReason)
        .onChange(of: activity.failureReason) { _, reason in
            if reason == nil { dismissedFailureReason = nil }
        }
        .onAppear(perform: registerKeyboardObservers)
        .onDisappear(perform: removeKeyboardObservers)
    }

    private func registerKeyboardObservers() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(of: UIScreen.self, for: .keyboardWillShow) { _ in
                keyboardVisible = true
            },
            center.addObserver(of: UIScreen.self, for: .keyboardWillHide) { _ in
                keyboardVisible = false
            },
        ]
    }

    private func removeKeyboardObservers() {
        for token in keyboardObservers {
            NotificationCenter.default.removeObserver(token)
        }
        keyboardObservers = []
    }

    /// The sticky failure — an LLM error or the model's request for
    /// clarification — to surface over the panel, unless already dismissed.
    private var visibleFailureReason: String? {
        guard let reason = activity.failureReason,
              reason != dismissedFailureReason
        else { return nil }
        return reason
    }

    /// Fills the whole panel with the failure message until the user
    /// dismisses it back to the panel's regular content.
    private func failureOverlay(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            ScrollView {
                Text(reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            Button {
                dismissedFailureReason = reason
            } label: {
                aiKitText("Dismiss")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(AIKitMetrics.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
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

struct AssistantTabBottomAccessory: View {
    // No state of its own: selecting the search/FAB tab — even for the one
    // frame a tap produces — rebuilds the accessory, so anything stored here
    // resets (the activity would flash back to idle until a fresh
    // subscription delivered the real state). `AIKitChatbotTabBar` owns the
    // coordinator and the activity subscription and passes them in.
    let input: AssistantInputCoordinator
    let activity: OrchestratorActivity
    @FocusState private var fieldFocused: Bool

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
        //
        // No .ignoresSafeArea(.keyboard) either: the system positions the
        // accessory relative to the keyboard, so a keyboard-dependent
        // safe-area attribute inside it makes the layout self-referential —
        // AttributeGraph reports a cycle storm while the accessory
        // re-anchors (e.g. switching tabs with the keyboard up).
        .frame(maxWidth: .infinity, minHeight: 44)
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

struct AIKitTabFabOverlayModifier<ViewContent: View>: ViewModifier {
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
                            // A container panel, not a tappable element, so use
                            // plain `.regular` glass. `.interactive()` Liquid
                            // Glass installs its own touch-responsive layer that
                            // offsets/swallows hits meant for the controls nested
                            // inside the panel — the Memory/Tools/Activity
                            // segmented menu only responded in a shifted region,
                            // which read as "needs 2+ taps". No explicit
                            // `.contentShape` either: applied before the
                            // bottom-aligning frame its hit region didn't track
                            // the visible glass, and the glass background already
                            // makes the panel hittable.
                            .glassEffect(.regular, in: .rect(cornerRadius: 30))
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

