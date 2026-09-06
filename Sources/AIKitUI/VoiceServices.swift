import Foundation
import MultiModalKit

/// Real audio boundaries are injectable so lifecycle tests never open a mic.
@MainActor
protocol AIKitVoiceSpeechSession: AnyObject, Sendable {
    var audioLevel: Double { get }
    func start() async throws
    func awaitSilence() async throws
    func awaitKeyword(_ word: String) async throws
    func finish() async -> String
    func cancel()
}

extension LiveSpeechSession: AIKitVoiceSpeechSession {}

@MainActor
protocol AIKitAudioRecording: AnyObject {
    var isRecording: Bool { get }
    var averagePowerLevel: Double { get }
    var peakPowerLevel: Double { get }
    func start() async throws
    func stop() -> URL?
    func cancel()
}

@MainActor
final class AIKitAudioRecorder: AIKitAudioRecording {
    private let recorder = AudioRecorder()
    var isRecording: Bool { recorder.isRecording }
    var averagePowerLevel: Double { recorder.averagePowerLevel }
    var peakPowerLevel: Double { recorder.peakPowerLevel }
    func start() async throws {
        try await PermissionCenter.require(.speechRecognition)
        try Task.checkCancellation()
        _ = try await recorder.startRecordingWithPermission(configuration: .init(format: .wav))
    }
    func stop() -> URL? { recorder.stopRecording() }
    func cancel() { recorder.cancelRecording() }
}
