import SwiftUI
import Observation
import AIKitCore
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
    public private(set) var lines: [Line] = []
    public private(set) var isRunning = false
    public private(set) var lastError: String?

    private let orchestrator: Orchestrator

    public init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    public func send(_ instruction: String) async {
        guard !instruction.isEmpty, !isRunning else { return }
        isRunning = true
        lastError = nil
        streamingText = ""
        lines.append(Line(role: "you", text: instruction))

        do {
            for try await event in await orchestrator.run(instruction) {
                switch event {
                case .llmDelta(let delta):
                    streamingText += delta
                case .toolCall(let name, _):
                    lines.append(Line(role: "tool", text: "→ \(name)"))
                case .toolResult(let name, let output):
                    lines.append(Line(
                        role: "tool",
                        text: "\(name): \(String(decoding: output, as: UTF8.self))"
                    ))
                case .verification(let stage, let outcome):
                    if case .warn(let reason) = outcome {
                        lines.append(Line(role: "warn", text: "[\(stage.rawValue)] \(reason)"))
                    }
                case .finalAnswer(let text):
                    lines.append(Line(role: "assistant", text: text))
                    streamingText = ""
                case .error(let error):
                    lastError = "\(error)"
                case .promptBuilt:
                    break
                }
            }
        } catch {
            lastError = "\(error)"
        }
        isRunning = false
    }
}

/// A minimal SwiftUI view that renders an `Orchestrator`'s event stream:
/// a transcript, live streaming text, and a prompt field.
public struct AIKitView: View {
    @State private var session: AIKitSession
    @State private var draft: String = ""

    public init(orchestrator: Orchestrator) {
        _session = State(initialValue: AIKitSession(orchestrator: orchestrator))
    }

    public var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.role.uppercased())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !session.streamingText.isEmpty {
                        Text(session.streamingText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }

            if let error = session.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            HStack {
                TextField("Ask AIKit…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.isRunning)
                    .onSubmit(submit)
                Button("Send", action: submit)
                    .disabled(session.isRunning || draft.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func submit() {
        let instruction = draft
        draft = ""
        Task { await session.send(instruction) }
    }
}
