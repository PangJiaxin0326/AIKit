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
        case stopping
    }

    private(set) var phase: Phase = .idle
    /// Set when setup fails (permission denied, speech unavailable). Cleared
    /// when the next conversation starts.
    private(set) var errorMessage: String?
    /// The recorder backing the current listening / thinking phase, exposed
    /// so the button can react to its live input level.
    private(set) var activeSpeech: (any AIKitVoiceSpeechSession)?

    @ObservationIgnored private let respond: @Sendable (String) async throws -> String
    @ObservationIgnored private let makeSpeech: @MainActor () -> any AIKitVoiceSpeechSession
    @ObservationIgnored private let managesAudioSession: Bool
    @ObservationIgnored private let synthesizer = SpeechSynthesizer()
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    init(
        conversation: AIKitConversation,
        makeSpeech: @escaping @MainActor () -> any AIKitVoiceSpeechSession = { LiveSpeechSession() },
        managesAudioSession: Bool = true
    ) {
        self.makeSpeech = makeSpeech
        self.managesAudioSession = managesAudioSession
        respond = { try await conversation.collectResponse(to: $0).content }
    }

    init(orchestrator: Orchestrator) {
        makeSpeech = { LiveSpeechSession() }
        managesAudioSession = true
        respond = { instruction in
            var answer = ""
            for try await event in await orchestrator.run(instruction) {
                switch event {
                case .finalAnswer(let text): answer = text
                case .failure(let reason): throw TurnRefusal(reason: reason)
                case .error(let error): throw error
                default: break
                }
            }
            try Task.checkCancellation()
            return answer
        }
    }

    /// Live input level of the active recorder, `0...1`.
    var canStart: Bool { flowTask == nil }
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
        // Keep ownership until cancellation and audio cleanup settle.
        // A new flow cannot race the previous flow's asynchronous cleanup.
        synthesizer.stop()
        activeSpeech?.cancel()
        activeSpeech = nil
        deactivateAudioSession()
        phase = flowTask == nil ? .idle : .stopping
    }

    // MARK: - Conversation flow

    private enum Outcome {
        case completed
        case needsFollowUp(String)
        case stopped
        case empty
    }

    private func runConversation() async {
        await activateAudioSession()
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
                    aiKitContextualFollowUpInstruction(
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
        let session = makeSpeech()
        activeSpeech = session
        do {
            try await session.start()
            try await session.awaitSilence()
        } catch {
            _ = await session.finish()
            activeSpeech = nil
            throw error
        }
        let transcript = await session.finish()
        activeSpeech = nil
        return transcript
    }

    /// Runs one orchestrator turn while a second recorder listens for "stop".
    private func think(instruction: String) async -> Outcome {
        let stopListener = makeSpeech()
        activeSpeech = stopListener
        let listeningForStop = ((try? await stopListener.start()) != nil)

        let respond = respond
        let outcome = await withTaskGroup(of: Outcome?.self) { group -> Outcome in
            group.addTask {
                await Self.runTurn(respond: respond, instruction: instruction)
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
                group.cancelAll()
                break
            }
            return resolved
        }

        stopListener.cancel()
        activeSpeech = nil
        return outcome
    }

    /// Group cancellation reaches the same conversation turn lifecycle.
    private static func runTurn(
        respond: @Sendable (String) async throws -> String,
        instruction: String
    ) async -> Outcome {
        do {
            let answer = try await respond(instruction)
            try Task.checkCancellation()
            return answer.isEmpty ? .empty : .completed
        } catch is CancellationError {
            return .stopped
        } catch {
            return .needsFollowUp(AIKitConversationPresenter.describe(error))
        }
    }

    // MARK: - Audio session

    #if os(iOS) || os(visionOS)
    /// `setCategory`/`setActive` block the calling thread, so session work runs
    /// on this serial queue: it keeps the main thread responsive while keeping
    /// activations ordered with respect to fire-and-forget deactivations.
    private nonisolated static let audioSessionQueue = DispatchQueue(
        label: "AIKitUI.VoiceModeController.AudioSession"
    )
    #endif

    private func activateAudioSession() async {
        guard managesAudioSession else { return }
        #if os(iOS) || os(visionOS)
        await withCheckedContinuation { continuation in
            Self.audioSessionQueue.async {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.defaultToSpeaker, .duckOthers]
                )
                try? session.setActive(true, options: .notifyOthersOnDeactivation)
                continuation.resume()
            }
        }
        #endif
    }

    private func deactivateAudioSession() {
        guard managesAudioSession else { return }
        #if os(iOS) || os(visionOS)
        Self.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        #endif
    }
}
