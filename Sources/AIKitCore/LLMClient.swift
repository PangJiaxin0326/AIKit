import Foundation

/// A thin, `Sendable` wrapper around any `LLMProvider`. Adds no behavior beyond
/// forwarding; statefulness lives in the Runtime layer.
public struct LLMClient: Sendable {
    private let provider: any LLMProvider

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    /// The provider's default model, used by the Runtime when the orchestrator
    /// options don't pin a model explicitly.
    public var defaultModel: String { provider.defaultModel }

    /// Whether the underlying provider speaks a native function-calling
    /// protocol. The Runtime uses this to decide whether to inject the fenced
    /// tool-call fallback when `Options.toolCallFallback` is left unset.
    public var supportsNativeTools: Bool { provider.supportsNativeTools }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await provider.complete(request)
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        provider.stream(request)
    }
}
