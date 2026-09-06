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

/// A SwiftUI state-management surface for AIKit's Core, Capability, Runtime,
/// and Safety configuration.
public struct AIKitView: View {
    @State private var model: AIKitConfigurationViewModel
    @State private var providerCredentials: AIKitProviderCredentialStore

    private let orchestrator: Orchestrator?
    private let credentialStorage: any AIKitCredentialStorage

    @MainActor
    public init(
        configurationStore: AIKitConfigurationStore = AIKitConfigurationStore(),
        tools: [any Tool] = [],
        credentialStorage: any AIKitCredentialStorage = AIKitKeychainCredentialStorage(),
        modelCatalog: any AIKitModelCatalogFetching = AIKitStaticModelCatalog()
    ) {
        self.credentialStorage = credentialStorage
        self.orchestrator = nil
        _model = State(initialValue: AIKitConfigurationViewModel(
            store: configurationStore,
            tools: tools,
            modelCatalog: modelCatalog
        ))
        _providerCredentials = State(initialValue: AIKitProviderCredentialStore())
    }

    @MainActor
    public init(
        orchestrator: Orchestrator,
        configurationStore: AIKitConfigurationStore = AIKitConfigurationStore(),
        tools: [any Tool] = [],
        credentialStorage: any AIKitCredentialStorage = AIKitKeychainCredentialStorage(),
        modelCatalog: any AIKitModelCatalogFetching = AIKitStaticModelCatalog()
    ) {
        self.credentialStorage = credentialStorage
        self.orchestrator = orchestrator
        _model = State(initialValue: AIKitConfigurationViewModel(
            store: configurationStore,
            tools: tools,
            modelCatalog: modelCatalog
        ))
        _providerCredentials = State(initialValue: AIKitProviderCredentialStore())
    }

    @ViewBuilder
    public var body: some View {
        dashboard
            .task {
                do { providerCredentials = try AIKitProviderCredentialStore.load(storage: credentialStorage) }
                catch { model.status = error.localizedDescription }
            }
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
        .aiKitGlassEffect(tint: tint.opacity(0.08), in: Capsule())
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
                    Text(AIKitUILocalization.string(
                        "None (\(modelOptions.count) models available)"
                    ))
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

            if model.supportsModelRefresh(for: selectedProvider) {
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
                    .aiKitGlassEffect(
                        tint: Color.indigo.opacity(0.08),
                        interactive: true,
                        in: Circle()
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
        }
    }

    private var safetySection: some View {
        AIKitConfigurationSection(title: "Safety", systemImage: "shield.lefthalf.filled", tint: .green) {
            Toggle(isOn: binding(\.safety.piiGuardEnabled)) {
                aiKitText("PII guard")
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
        AIKitGlassContainer(spacing: 10) {
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
                .aiKitGlassButtonStyle()
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
                var updated = providerCredentials
                updated.setAPIKey(newValue, for: selectedProvider)
                do {
                    try updated.save(storage: credentialStorage)
                    providerCredentials = updated
                    model.status = "Credential saved securely"
                } catch { model.status = error.localizedDescription }
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

    private func binding<Value: Sendable>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value> & Sendable
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { model.update(keyPath, to: $0) }
        )
    }

    /// A text binding for an optional numeric config field: shows the value's
    /// string form (empty when unset) and writes back the parsed value, or
    /// `nil` when the text doesn't parse (empty field ⇒ "use the default").
    private func optionalNumberBinding<Value: LosslessStringConvertible & Sendable>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value?> & Sendable
    ) -> Binding<String> {
        Binding(
            get: { model.configuration[keyPath: keyPath]?.description ?? "" },
            set: { model.update(keyPath, to: Value($0)) }
        )
    }

    private func setBinding(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Set<String>> & Sendable
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
@MainActor
@Observable
final class AIKitConfigurationViewModel {
    var configuration: AIKitConfiguration
    var availableTools: [ToolDescriptor] = []
    var recentChanges: [AIKitConfigurationChange] = []
    var status: String?

    private let store: AIKitConfigurationStore
    private let tools: [any Tool]
    private let modelCatalog: any AIKitModelCatalogFetching
    private var refreshingProviders: Set<AIKitProviderKind> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(
        store: AIKitConfigurationStore,
        tools: [any Tool],
        modelCatalog: any AIKitModelCatalogFetching = AIKitStaticModelCatalog()
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
        availableTools = tools.map(\.descriptor).sorted { $0.name < $1.name }
        for await snapshot in await store.updates() {
            configuration = snapshot
            recentChanges = await store.recentChanges(limit: 6)
        }
    }

    func modelOptions(for provider: AIKitProviderKind) -> [String] {
        let configuredModels = configuration.core.providerConfiguration(for: provider).availableModels
        return configuredModels.isEmpty ? provider.definition.staticModelIDs : configuredModels
    }

    func supportsModelRefresh(for provider: AIKitProviderKind) -> Bool {
        modelCatalog.supportsRefresh(for: provider)
    }

    func isRefreshingModels(for provider: AIKitProviderKind) -> Bool {
        refreshingProviders.contains(provider)
    }

    func selectProvider(_ provider: AIKitProviderKind) {
        update { $0.core.activeProvider = provider }
    }

    func selectModel(_ model: String?, for provider: AIKitProviderKind) {
        update { configuration in
            var value = configuration.core.providerConfiguration(for: provider)
            value.defaultModel = model?.emptyAsNil
            configuration.core.setProviderConfiguration(value, for: provider)
        }
    }

    func update<Value: Sendable>(
        _ keyPath: WritableKeyPath<AIKitConfiguration, Value> & Sendable,
        to value: Value
    ) {
        update { $0[keyPath: keyPath] = value }
    }

    func update(_ change: @escaping @Sendable (inout AIKitConfiguration) -> Void) {
        change(&configuration)
        // Preserve local edit order without cancelling writes already admitted
        // to the actor; each change applies to the store's current fields.
        let previous = saveTask
        saveTask = Task { [store] in
            await previous?.value
            await store.update(source: "AIKitView", change)
            self.recentChanges = await store.recentChanges(limit: 6)
            self.status = "Updated in memory; host applies to new sessions"
        }
    }

    func resetToDefaults() {
        update { $0 = .standard }
    }

    func refreshModels(
        provider: AIKitProviderKind,
        apiKey: String
    ) async {
        guard supportsModelRefresh(for: provider), !refreshingProviders.contains(provider) else { return }
        refreshingProviders.insert(provider)
        defer { refreshingProviders.remove(provider) }

        do {
            let models = try await modelCatalog.fetchModels(
                for: provider,
                apiKey: apiKey,
                timeout: configuration.core.timeout
            )
            update { configuration in
                var value = configuration.core.providerConfiguration(for: provider)
                value.replaceAvailableModels(models)
                configuration.core.setProviderConfiguration(value, for: provider)
            }
        } catch {
            status = error.localizedDescription
        }
    }
}

struct AIKitConfigurationSection<Content: View>: View {
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

struct AIKitTextFieldRowStyle: LabeledContentStyle {
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

struct AIKitSummaryChip: View {
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

struct AIKitPickerCapsuleLabel: View {
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
