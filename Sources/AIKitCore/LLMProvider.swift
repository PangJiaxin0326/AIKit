import Foundation

/// Configuration shared by built-in providers. The host app owns the API key;
/// the package never reads environment variables.
public struct LLMProviderConfiguration: Sendable {
    /// API credential. An empty string means "no auth" — the provider omits the
    /// auth header entirely, which is what local backends (Ollama, llama.cpp,
    /// vLLM in no-auth mode) expect.
    public var apiKey: String
    public var baseURL: URL
    public var defaultModel: String
    /// Per-request timeout. `nil` falls back to the `URLSession` default.
    public var timeout: TimeInterval?
    /// Injected so tests can supply a `URLProtocol`-stubbed session.
    public var session: URLSession

    public init(
        apiKey: String,
        baseURL: URL,
        defaultModel: String,
        timeout: TimeInterval? = nil,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.timeout = timeout
        self.session = session
    }
}

/// A stateless transport to an LLM. No memory, retries, or parsing.
public protocol LLMProvider: Sendable {
    /// The model used when an `LLMRequest` does not override it. Lets the
    /// Runtime resolve a single source of truth for "which model".
    var defaultModel: String { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMResponseChunk, any Error>
}

/// Merges provider-specific `extraBody` keys into an already-encoded request
/// body. Uses `JSONSerialization` so the encoder's original numeric types
/// (e.g. an integer `max_tokens`) survive — round-tripping through a `Double`
/// representation can make strict providers reject the request.
///
/// Reserved keys (owned by the wire encoder) are never overwritten.
func mergedRequestBody(
    encoded: Data,
    extraBody: [String: JSONValue],
    reservedKeys: Set<String>
) throws -> Data {
    guard !extraBody.isEmpty else { return encoded }
    guard var object = try JSONSerialization.jsonObject(
        with: encoded
    ) as? [String: Any] else {
        return encoded
    }
    let extraData = try JSONEncoder().encode(extraBody)
    let extra = try JSONSerialization.jsonObject(with: extraData) as? [String: Any] ?? [:]
    for (key, value) in extra where !reservedKeys.contains(key) {
        object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
}

extension URL {
    /// Resolves a provider endpoint, tolerating the common ways a base URL is
    /// written. Given `apiPrefix` `"v1"` and `endpoint` `"chat/completions"`:
    ///
    /// - `https://api.openai.com`          → `…/v1/chat/completions`
    /// - `http://host:11434/v1`            → `…/v1/chat/completions` (no double `v1`)
    /// - `http://host:11434/v1/`           → trailing slash tolerated
    /// - `http://host/v1/chat/completions` → used verbatim (full override)
    func resolvingEndpoint(apiPrefix: String, endpoint: String) -> URL {
        let trimmed = absoluteString.hasSuffix("/")
            ? String(absoluteString.dropLast())
            : absoluteString
        let fullPath = "\(apiPrefix)/\(endpoint)"
        if trimmed.hasSuffix("/\(fullPath)") {
            return URL(string: trimmed) ?? self
        }
        if trimmed.hasSuffix("/\(apiPrefix)") {
            return URL(string: "\(trimmed)/\(endpoint)") ?? self
        }
        return URL(string: "\(trimmed)/\(fullPath)") ?? self
    }
}
