import Foundation
import Synchronization
import AIToolKit
import AIKitCore

/// A scripted `LLMProvider` for tests. Returns queued responses in order; the
/// streaming path decomposes each response into chunks.
public final class MockProvider: LLMProvider, Sendable {
    private struct Script {
        var scripted: [Result<LLMResponse, LLMError>]
        var index = 0
        var receivedRequests: [LLMRequest] = []
    }

    private let script: Mutex<Script>

    public let configuration: LLMProviderConfiguration
    public let supportsNativeTools: Bool

    public var receivedRequests: [LLMRequest] {
        script.withLock { $0.receivedRequests }
    }

    public init(
        responses: [LLMResponse],
        defaultModel: String? = "mock-model",
        availableModels: [String] = [],
        supportsNativeTools: Bool = true
    ) {
        self.script = Mutex(Script(scripted: responses.map { .success($0) }))
        self.configuration = LLMProviderConfiguration(
            apiKey: "",
            baseURL: URL(string: "mock://provider")!,
            defaultModel: defaultModel,
            availableModels: availableModels
        )
        self.supportsNativeTools = supportsNativeTools
    }

    public init(
        results: [Result<LLMResponse, LLMError>],
        defaultModel: String? = "mock-model",
        availableModels: [String] = [],
        supportsNativeTools: Bool = true
    ) {
        self.script = Mutex(Script(scripted: results))
        self.configuration = LLMProviderConfiguration(
            apiKey: "",
            baseURL: URL(string: "mock://provider")!,
            defaultModel: defaultModel,
            availableModels: availableModels
        )
        self.supportsNativeTools = supportsNativeTools
    }

    /// Convenience: a single final-text response.
    public convenience init(finalText: String) {
        self.init(responses: [
            LLMResponse(content: [.text(finalText)], stopReason: .endTurn)
        ])
    }

    private func next(for request: LLMRequest) throws -> LLMResponse {
        try script.withLock { script in
            script.receivedRequests.append(request)
            guard script.index < script.scripted.count else {
                throw LLMError.provider(message: "MockProvider exhausted")
            }
            let result = script.scripted[script.index]
            script.index += 1
            return try result.get()
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try next(for: request)
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try next(for: request)
                for block in response.content {
                    switch block {
                    case .text(let text):
                        continuation.yield(.textDelta(text))
                    case .reasoning(let text):
                        continuation.yield(.reasoningDelta(text))
                    case .image:
                        break
                    case .toolUse(let id, let name, let arguments):
                        continuation.yield(.toolUseStart(id: id, name: name))
                        let json = String(decoding: arguments.data(), as: UTF8.self)
                        continuation.yield(.toolUseInputDelta(id: id, json: json))
                        continuation.yield(.toolUseStop(id: id))
                    case .toolResult:
                        break
                    }
                }
                continuation.yield(.stop(response.stopReason))
                continuation.yield(.usage(response.usage))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
