@preconcurrency import AVFoundation
import Foundation
import Observation
import AIKitCore
import AIKitRuntime
import MultiModalKit

/// Drives the pure-voice ("AI") chatbot mode as a state machine:
///
/// 1. `listening` — capture an instruction by voice until silence.
/// 2. `thinking` — run one orchestrator turn while a second recorder listens
///    for the word "stop", which cancels the turn.
/// 3. On success the conversation ends. On failure (or a request for more
///    information) the assistant's reply is spoken, then listening resumes
///    for a follow-up — folding the failed turn in as context.
@MainActor
@Observable
final class VoiceModeController {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    private(set) var phase: Phase = .idle
    /// Set when setup fails (permission denied, speech unavailable). Cleared
    /// when the next conversation starts.
    private(set) var errorMessage: String?
    /// The recorder backing the current listening / thinking phase, exposed
    /// so the button can react to its live input level.
    private(set) var activeSpeech: LiveSpeechSession?

    @ObservationIgnored private let orchestrator: Orchestrator
    @ObservationIgnored private let synthesizer = SpeechSynthesizer()
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    /// Live input level of the active recorder, `0...1`.
    var audioLevel: Double { activeSpeech?.audioLevel ?? 0 }

    // MARK: - Intent

    /// The button's tap handler: begins a conversation when idle, otherwise
    /// aborts the one in progress.
    func toggle() {
        if phase == .idle {
            begin()
        } else {
            abort()
        }
    }

    private func begin() {
        guard flowTask == nil else { return }
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConversation()
        }
        flowTask = task
        Task { [weak self] in
            _ = await task.value
            guard let self, self.flowTask == task else { return }
            self.flowTask = nil
        }
    }

    /// Stops everything and returns to idle.
    func abort() {
        flowTask?.cancel()
        flowTask = nil
        synthesizer.stop()
        activeSpeech?.cancel()
        activeSpeech = nil
        let orchestrator = orchestrator
        Task { await orchestrator.cancelActiveTurns() }
        deactivateAudioSession()
        phase = .idle
    }

    // MARK: - Conversation flow

    private enum Outcome {
        case completed
        case needsFollowUp(String)
        case stopped
        case empty
    }

    private func runConversation() async {
        activateAudioSession()
        defer {
            deactivateAudioSession()
            activeSpeech = nil
            phase = .idle
        }

        var pendingFollowUp: (instruction: String, reason: String)?
        do {
            while true {
                try Task.checkCancellation()

                // 1. Listen for an instruction.
                phase = .listening
                let spoken = try await listen()
                try Task.checkCancellation()
                guard !spoken.isEmpty else { return }

                let instruction = pendingFollowUp.map {
                    Self.followUpInstruction(
                        previous: $0.instruction,
                        reason: $0.reason,
                        followUp: spoken
                    )
                } ?? spoken

                // 2. Run the turn while listening for "stop".
                phase = .thinking
                let outcome = await think(instruction: instruction)
                try Task.checkCancellation()

                // 3. Branch on the result.
                switch outcome {
                case .completed, .stopped, .empty:
                    return
                case .needsFollowUp(let reply):
                    phase = .speaking
                    await synthesizer.speak(reply)
                    try Task.checkCancellation()
                    pendingFollowUp = (instruction: spoken, reason: reply)
                }
            }
        } catch is CancellationError {
            // Aborted — `defer` resets state.
        } catch {
            errorMessage = error.localizedDescription
            AIKitLog.ui.error("Voice conversation failed: \(error)")
        }
    }

    /// Captures one spoken instruction, returning the transcript.
    private func listen() async throws -> String {
        let session = LiveSpeechSession()
        activeSpeech = session
        do {
            try await session.start()
            try await session.awaitSilence()
        } catch {
            await session.finish()
            activeSpeech = nil
            throw error
        }
        let transcript = await session.finish()
        activeSpeech = nil
        return transcript
    }

    /// Runs one orchestrator turn while a second recorder listens for "stop".
    private func think(instruction: String) async -> Outcome {
        let stopListener = LiveSpeechSession()
        activeSpeech = stopListener
        let listeningForStop = ((try? await stopListener.start()) != nil)

        let orchestrator = orchestrator
        let outcome = await withTaskGroup(of: Outcome?.self) { group -> Outcome in
            group.addTask {
                await Self.runTurn(orchestrator: orchestrator, instruction: instruction)
            }
            if listeningForStop {
                group.addTask {
                    do {
                        try await stopListener.awaitKeyword("stop")
                        return .stopped
                    } catch {
                        return nil
                    }
                }
            }

            var resolved: Outcome = .empty
            while let next = await group.next() {
                guard let value = next else { continue }
                resolved = value
                if case .stopped = value {
                    await orchestrator.cancelActiveTurns()
                }
                group.cancelAll()
                break
            }
            return resolved
        }

        stopListener.cancel()
        activeSpeech = nil
        return outcome
    }

    /// Consumes one orchestrator turn and classifies its result.
    private static func runTurn(
        orchestrator: Orchestrator,
        instruction: String
    ) async -> Outcome {
        var finalAnswer: String?
        var failure: String?
        do {
            for try await event in await orchestrator.run(instruction) {
                switch event {
                case .finalAnswer(let text):
                    finalAnswer = text
                case .failure(let reason):
                    failure = reason
                case .error(let error):
                    failure = AIKitSession.describe(error)
                default:
                    break
                }
            }
        } catch is CancellationError {
            return .empty
        } catch {
            failure = AIKitSession.describe(error)
        }

        if let failure, !failure.isEmpty { return .needsFollowUp(failure) }
        if let finalAnswer, !finalAnswer.isEmpty { return .completed }
        return .empty
    }

    /// Folds a failed turn and the spoken clarification into one instruction,
    /// so the model treats the follow-up as part of the same request.
    private static func followUpInstruction(
        previous: String,
        reason: String,
        followUp: String
    ) -> String {
        """
        This is a follow-up to a request you could not complete.
        Your earlier request was: "\(previous)"
        It could not be completed because: \(reason)
        Clarification / new instruction: \(followUp)
        Treat the earlier request and this clarification as one request.
        """
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .duckOthers]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}
