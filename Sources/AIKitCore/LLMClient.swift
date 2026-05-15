import Foundation

/// A thin, `Sendable` wrapper around any `LLMProvider`. Adds no behavior beyond
/// forwarding; statefulness lives in the Runtime layer.
public struct LLMClient: Sendable {
    private let provider: any LLMProvider

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await provider.complete(request)
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        provider.stream(request)
    }
}
