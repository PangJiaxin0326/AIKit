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
    public private(set) var lines: [Line] = []
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Cumulative token usage across every turn this session has run, so hosts
    /// can show cost/telemetry without wiring the event stream themselves.
    public private(set) var totalUsage = TokenUsage.zero

    private let orchestrator: Orchestrator

    public init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    /// Renders an error with its safety detail intact. A `GuardrailViolation`
    /// surfaced as a bare description loses the rail id and stage; spell them
    /// out so the host gets a usable safety story out of the box.
    private static func describe(_ error: any Error) -> String {
        if let violation = error as? GuardrailViolation {
            return "Blocked by \(violation.railID) at \(violation.stage.rawValue): \(violation.reason)"
        }
        if let iteration = error as? IterationLimitExceeded {
            return "Stopped after reaching the \(iteration.limit)-iteration limit."
        }
        if let llmError = error as? LLMError {
            return llmError.errorDescription ?? "\(llmError)"
        }
        return "\(error)"
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
