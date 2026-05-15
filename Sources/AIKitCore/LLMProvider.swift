import Foundation

/// Configuration shared by built-in providers. The host app owns the API key;
/// the package never reads environment variables.
public struct LLMProviderConfiguration: Sendable {
    public var apiKey: String
    public var baseURL: URL
    public var defaultModel: String
    /// Injected so tests can supply a `URLProtocol`-stubbed session.
    public var session: URLSession

    public init(
        apiKey: String,
        baseURL: URL,
        defaultModel: String,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.session = session
    }
}

/// A stateless transport to an LLM. No memory, retries, or parsing.
public protocol LLMProvider: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMResponseChunk, any Error>
}
