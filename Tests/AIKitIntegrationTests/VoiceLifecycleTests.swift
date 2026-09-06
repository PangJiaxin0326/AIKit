import Foundation
import FoundationModels
import Testing
import AIKitRuntime
import AIKitTestSupport
@testable import AIKitUI

@MainActor
private final class PendingAudioRecorder: AIKitAudioRecording {
    var isRecording = false
    var averagePowerLevel: Double { 0 }
    var peakPowerLevel: Double { 0 }
    var starts = 0
    var cancellationCount = 0
    private var permission: CheckedContinuation<Void, Never>?

    func start() async throws {
        starts += 1
        await withCheckedContinuation { permission = $0 }
        isRecording = true // Simulates late permission completion after cancel.
    }
    func grantPermission() { permission?.resume(); permission = nil }
    func stop() -> URL? { nil }
    func cancel() { isRecording = false; cancellationCount += 1 }
}

@MainActor
private final class PendingSpeechSession: AIKitVoiceSpeechSession {
    var audioLevel: Double { 0 }
    var starts = 0
    private var permission: CheckedContinuation<Void, Never>?
    func start() async throws {
        starts += 1
        await withCheckedContinuation { permission = $0 }
    }
    func grantPermission() { permission?.resume(); permission = nil }
    func awaitSilence() async throws { try Task.checkCancellation() }
    func awaitKeyword(_ word: String) async throws { try Task.checkCancellation() }
    func finish() async -> String { "hello" }
    func cancel() {}
}

@Suite struct VoiceLifecycleTests {
    @MainActor @Test func cancelledPermissionCannotResetANewRecording() async {
        let recorder = PendingAudioRecorder()
        let input = AssistantVoiceInputController(recorder: recorder)
        input.startRecording()
        while recorder.starts == 0 { await Task.yield() }
        input.cancel()
        input.startRecording()
        #expect(recorder.starts == 1)
        #expect(input.isStarting)
        recorder.grantPermission()
        while input.isStarting { await Task.yield() }
        #expect(!input.isRecording)
        #expect(!recorder.isRecording)
        #expect(recorder.cancellationCount > 0)
        input.startRecording()
        while recorder.starts < 2 { await Task.yield() }
        recorder.grantPermission()
        while input.isStarting { await Task.yield() }
        #expect(input.isRecording)
        input.cancel()
    }

    private nonisolated static func conversation() -> AIKitConversation {
        AIKitConversation(session: LanguageModelSession(profile:
            LanguageModelSession.Profile { Instructions("Help") }.model(MockLanguageModel(finalText: "unused"))))
    }

    @MainActor @Test func voiceRestartWaitsForOldFlowCleanup() async {
        let speech = PendingSpeechSession()
        let controller = VoiceModeController(conversation: Self.conversation(), makeSpeech: { speech }, managesAudioSession: false)
        controller.toggle()
        while speech.starts == 0 { await Task.yield() }
        controller.abort()
        #expect(controller.phase == .stopping)
        controller.toggle()
        #expect(speech.starts == 1)
        speech.grantPermission()
        while !controller.canStart { await Task.yield() }
        #expect(controller.phase == .idle)
        controller.toggle()
        while speech.starts < 2 { await Task.yield() }
        controller.abort()
        speech.grantPermission()
        while !controller.canStart { await Task.yield() }
        #expect(controller.phase == .idle)
    }
}
