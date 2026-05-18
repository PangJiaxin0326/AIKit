import Foundation
import AIKitCore

/// A scripted `LLMProvider` for tests. Returns queued responses in order; the
/// streaming path decomposes each response into chunks.
public final class MockProvider: LLMProvider, @unchecked Sendable {
    // swiftlint:disable:next - mutable script guarded by `lock`; not part of public concurrency surface
    private let lock = NSLock()
    private var scripted: [Result<LLMResponse, LLMError>]
    private var index = 0
    public private(set) var receivedRequests: [LLMRequest] = []

    public let defaultModel: String
    public let supportsNativeTools: Bool

    public init(
        responses: [LLMResponse],
        defaultModel: String = "mock-model",
        supportsNativeTools: Bool = true
    ) {
        self.scripted = responses.map { .success($0) }
        self.defaultModel = defaultModel
        self.supportsNativeTools = supportsNativeTools
    }

    public init(
        results: [Result<LLMResponse, LLMError>],
        defaultModel: String = "mock-model",
        supportsNativeTools: Bool = true
    ) {
        self.scripted = results
        self.defaultModel = defaultModel
        self.supportsNativeTools = supportsNativeTools
    }

    /// Convenience: a single final-text response.
    public convenience init(finalText: String) {
        self.init(responses: [
            LLMResponse(content: [.text(finalText)], stopReason: .endTurn)
        ])
    }

    private func next(for request: LLMRequest) throws -> LLMResponse {
        lock.lock()
        defer { lock.unlock() }
        receivedRequests.append(request)
        guard index < scripted.count else {
            throw LLMError.provider(message: "MockProvider exhausted")
        }
        let result = scripted[index]
        index += 1
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
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
                    case .audio(let audio):
                        continuation.yield(.audio(audio))
                    case .toolUse(let id, let name, let input):
                        continuation.yield(.toolUseStart(id: id, name: name))
                        if let data = try? input.data(),
                           let json = String(data: data, encoding: .utf8) {
                            continuation.yield(.toolUseInputDelta(id: id, json: json))
                        }
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
