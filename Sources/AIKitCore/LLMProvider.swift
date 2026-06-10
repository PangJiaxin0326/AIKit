import Foundation
import FoundationModels
import AIToolKit

/// Configuration shared by built-in providers. The host app owns the API key;
/// the package never reads environment variables.
public struct LLMProviderConfiguration: Sendable {
    /// API credential. An empty string means "no auth" — the provider omits the
    /// auth header entirely. Volcengine Ark requires a non-empty bearer token.
    public var apiKey: String
    public var baseURL: URL
    /// The model selected most recently by the host. `nil` means no model is
    /// selected, which lets UI surfaces offer an explicit "None" state.
    public var defaultModel: String?
    /// Models fetched from the provider's model-list endpoint.
    public var availableModels: [String]
    /// Per-request timeout. `nil` falls back to the `URLSession` default.
    public var timeout: TimeInterval?
    /// Injected so tests can supply a `URLProtocol`-stubbed session.
    public var session: URLSession

    public init(
        apiKey: String,
        baseURL: URL,
        defaultModel: String? = nil,
        availableModels: [String] = [],
        timeout: TimeInterval? = nil,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.defaultModel = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines).emptyAsNil
        self.availableModels = AIKitModelListNormalizer.uniquePreservingOrder(availableModels)
        self.timeout = timeout
        self.session = session
    }

    public mutating func replaceAvailableModels(_ models: [String]) {
        let replacement = AIKitModelListNormalizer.replacingAvailableModels(
            models,
            currentDefaultModel: defaultModel
        )
        availableModels = replacement.models
        defaultModel = replacement.defaultModel
    }

}

private extension String {
    var emptyAsNil: String? {
        isEmpty ? nil : self
    }
}

/// A stateless transport to an LLM. No memory, retries, or parsing.
public protocol LLMProvider: Sendable {
    /// Provider transport configuration, including the host-selected model
    /// and the latest fetched model list.
    var configuration: LLMProviderConfiguration { get }

    /// Stable, human-readable provider label for telemetry and usage records.
    /// Decorators should forward or override this so hosts persist the
    /// underlying provider label instead of an implementation type name.
    var providerName: String { get }

    /// Whether the Runtime can rely on native function calling for **every**
    /// model this provider serves.
    ///
    /// This is deliberately a guarantee, not a "the wire protocol has a
    /// `tool_calls` field" flag. When `true` the Runtime omits the
    /// fenced-```tool``` fallback (instruction + recovery parsing) so a
    /// native-capable model isn't prompted to emit both a native call and a
    /// redundant fenced block. When `false` it enables the fallback, which is
    /// purely *additive*: it only fires when a response carries no native tool
    /// call **and** contains a fenced block, so a native-capable model behind a
    /// `false` provider is unaffected.
    ///
    /// Because the fallback is additive, a provider whose tool support varies
    /// **per model** must report `false` — it cannot truthfully guarantee native
    /// tool calling for an arbitrary model. Defaults to `true` for providers
    /// that target a fixed API contract.
    var supportsNativeTools: Bool { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMResponseChunk, any Error>
}

public extension LLMProvider {
    var supportsNativeTools: Bool { true }

    var providerName: String { String(describing: Self.self) }
}
