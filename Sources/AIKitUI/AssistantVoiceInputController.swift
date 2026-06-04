import Foundation
import Observation
import MultiModalKit

@MainActor
@Observable
final class AssistantVoiceInputController {
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    @ObservationIgnored private var meteringTask: Task<Void, Never>?

    var isRecording = false
    var isVoiceTranscribing = false
    var voiceError: String?
    var voiceLevel: Double = 0

    func startRecording() {
        guard !isRecording, !isVoiceTranscribing else { return }
        voiceError = nil
        voiceLevel = 0
        voiceTask?.cancel()
        voiceTask = Task { @MainActor in
            do {
                try await PermissionCenter.require(.speechRecognition)
                try Task.checkCancellation()
                _ = try await recorder.startRecordingWithPermission(
                    configuration: AudioRecordingConfiguration(format: .wav)
                )
                isRecording = recorder.isRecording
                startMetering()
                voiceTask = nil
            } catch is CancellationError {
                recorder.cancelRecording()
                isRecording = false
                voiceTask = nil
                stopMetering()
            } catch {
                voiceError = error.localizedDescription
                recorder.cancelRecording()
                isRecording = false
                voiceTask = nil
                stopMetering()
            }
        }
    }

    func finishRecording(onText: @escaping @MainActor (String) -> Void) {
        guard let url = recorder.stopRecording() else {
            cancel()
            return
        }
        isRecording = false
        stopMetering()
        transcribeVoiceRecording(at: url, onText: onText)
    }

    func cancel() {
        voiceTask?.cancel()
        voiceTask = nil
        if recorder.isRecording {
            recorder.cancelRecording()
        }
        isRecording = false
        isVoiceTranscribing = false
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
                voiceTask = nil
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
                recorder.cancelRecording()
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
