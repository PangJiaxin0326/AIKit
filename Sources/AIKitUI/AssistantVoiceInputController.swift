import Foundation
import Observation
import MultiModalKit

@MainActor
@Observable
final class AssistantVoiceInputController {
    @ObservationIgnored private let recorder: any AIKitAudioRecording
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    @ObservationIgnored private var meteringTask: Task<Void, Never>?

    var isRecording = false
    var isStarting = false
    var isVoiceTranscribing = false
    var voiceError: String?
    var voiceLevel: Double = 0

    init(recorder: any AIKitAudioRecording = AIKitAudioRecorder()) {
        self.recorder = recorder
    }

    func startRecording() {
        guard voiceTask == nil, !isRecording, !isVoiceTranscribing else { return }
        voiceError = nil
        isStarting = true
        voiceLevel = 0
        voiceTask = Task { @MainActor in
            defer { isStarting = false; voiceTask = nil }
            do {
                try await recorder.start()
                try Task.checkCancellation()
                isRecording = recorder.isRecording
                startMetering()
            } catch is CancellationError {
                recorder.cancel()
                isRecording = false
                stopMetering()
            } catch {
                voiceError = error.localizedDescription
                recorder.cancel()
                isRecording = false
                stopMetering()
            }
        }
    }

    func finishRecording(onText: @escaping @MainActor (String) -> Void) {
        guard let url = recorder.stop() else {
            cancel()
            return
        }
        isRecording = false
        stopMetering()
        transcribeVoiceRecording(at: url, onText: onText)
    }

    func cancel() {
        voiceTask?.cancel()
        // The task retains ownership until permission/transcription cleanup.
        if recorder.isRecording {
            recorder.cancel()
        }
        isRecording = false
        if voiceTask == nil { isVoiceTranscribing = false }
        stopMetering()
    }

    func clearError() {
        voiceError = nil
    }

    private func transcribeVoiceRecording(
        at url: URL,
        onText: @escaping @MainActor (String) -> Void
    ) {
        isVoiceTranscribing = true
        voiceError = nil
        voiceTask?.cancel()
        voiceTask = Task { @MainActor [url] in
            defer {
                isVoiceTranscribing = false
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
                onText(text)
            } catch is CancellationError {
                recorder.cancel()
            } catch {
                voiceError = error.localizedDescription
            }
        }
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor in
            while !Task.isCancelled {
                voiceLevel = max(recorder.averagePowerLevel, recorder.peakPowerLevel * 0.85)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        voiceLevel = 0
    }

    deinit {
        voiceTask?.cancel()
        meteringTask?.cancel()
    }
}
