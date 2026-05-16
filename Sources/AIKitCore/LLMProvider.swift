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
    /// **per model** (Ollama: `llama3.1` calls tools natively, `gemma`/`phi`
    /// don't) must report `false` — it cannot truthfully guarantee native tool
    /// calling for an arbitrary model. Reporting `true` there silently breaks
    /// tool use for every tool-less local model under the default
    /// auto-resolution. Defaults to `true` for providers that target a fixed
    /// API contract (Anthropic, OpenAI).
    var supportsNativeTools: Bool { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMResponseChunk, any Error>
}

public extension LLMProvider {
    var supportsNativeTools: Bool { true }
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
    ///
    /// Throws `LLMError.unsupported` rather than silently returning `self`
    /// when the composed string isn't a valid URL: a misconfigured base URL
    /// should surface as a clear configuration error, not an opaque 404 from
    /// a request that quietly went to the bare base URL instead.
    func resolvingEndpoint(apiPrefix: String, endpoint: String) throws -> URL {
        let trimmed = absoluteString.hasSuffix("/")
            ? String(absoluteString.dropLast())
            : absoluteString
        let fullPath = "\(apiPrefix)/\(endpoint)"
        let composed: String
        if trimmed.hasSuffix("/\(fullPath)") {
            composed = trimmed
        } else if trimmed.hasSuffix("/\(apiPrefix)") {
            composed = "\(trimmed)/\(endpoint)"
        } else {
            composed = "\(trimmed)/\(fullPath)"
        }
        guard let url = URL(string: composed) else {
            throw LLMError.unsupported("invalid endpoint URL: \(composed)")
        }
        return url
    }
}
