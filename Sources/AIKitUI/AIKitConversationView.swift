import SwiftUI
import AIKitRuntime

/// The primary text and voice-input surface. A presenter owns validated
/// presentation; its conversation owns execution and activity settlement.
public struct AIKitConversationView: View {
    @State private var presenter: AIKitConversationPresenter
    @State private var voice = AssistantVoiceInputController()
    @State private var draft = ""
    @State private var turnTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    @MainActor
    public init(conversation: AIKitConversation) {
        _presenter = State(initialValue: AIKitConversationPresenter(conversation: conversation))
    }

    public var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(presenter.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            Text(line.text).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let prompt = presenter.pendingPrompt {
                        Text(prompt).frame(maxWidth: .infinity, alignment: .trailing)
                        ProgressView("Working…")
                    }
                    if let error = presenter.lastError {
                        Text(error).foregroundStyle(.red).accessibilityLabel("Assistant error: \(error)")
                    }
                    if let error = voice.voiceError { Text(error).foregroundStyle(.red) }
                }
                .padding()
            }
            HStack(alignment: .bottom) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .textFieldStyle(.roundedBorder)
                if presenter.isResponding {
                    Button("Cancel", systemImage: "stop.fill") { turnTask?.cancel() }
                        .labelStyle(.iconOnly)
                } else {
                    Button(voice.isRecording ? "Finish recording" : "Record message",
                           systemImage: voice.isRecording ? "stop.circle" : "mic") {
                        if voice.isRecording {
                            voice.finishRecording { text in draft = text }
                        } else { voice.startRecording() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(voice.isStarting || voice.isVoiceTranscribing)
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voice.isRecording)
                }
            }
            .padding()
        }
        .onDisappear {
            turnTask?.cancel()
            voice.cancel()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, turnTask == nil else { return }
        draft = ""
        inputFocused = false
        turnTask = Task {
            await presenter.send(text)
            turnTask = nil
        }
    }
}

struct ConversationAssistantOverlay<Details: View>: View {
    let conversation: AIKitConversation
    @ViewBuilder var details: () -> Details
    @State private var expanded = false

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button("Open assistant", systemImage: "sparkles") { expanded = true }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .padding()
                    .aiKitGlassEffect(interactive: true, in: Circle())
                    .popover(isPresented: $expanded) {
                        NavigationStack {
                            AIKitConversationView(conversation: conversation)
                                .navigationTitle("Assistant")
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") { expanded = false }
                                    }
                                    if Details.self != EmptyView.self {
                                        ToolbarItem(placement: .secondaryAction) {
                                            NavigationLink("Details") { details() }
                                        }
                                    }
                                }
                        }
                        .frame(idealWidth: 380, idealHeight: 520)
                        .presentationCompactAdaptation(.sheet)
                    }
            }
        }
        .padding()
    }
}

public extension View {
    func aiChatbotOverlay(
        conversation: AIKitConversation,
        context: AIKitOverlayContext = AIKitOverlayContext(),
        mode: AIKitChatbotOverlayMode = .assistant
    ) -> some View {
        overlay { AIKitChatbotOverlay(conversation: conversation, context: context, mode: mode) }
    }

    func aiChatbotOverlay<Details: View>(
        conversation: AIKitConversation,
        context: AIKitOverlayContext = AIKitOverlayContext(),
        mode: AIKitChatbotOverlayMode = .assistant,
        @ViewBuilder detailContent: @escaping @MainActor (AIKitOverlayContext) -> Details
    ) -> some View {
        overlay {
            AIKitChatbotOverlay(conversation: conversation, context: context, mode: mode, detailContent: detailContent)
        }
    }
}
