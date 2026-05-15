import Foundation

/// Typed errors thrown by the Core transport layer.
///
/// Underlying system errors are flattened to `String` to keep the type
/// `Sendable` without an `@unchecked` escape hatch.
public enum LLMError: Error, Sendable, Hashable {
    /// Provider returned a non-success HTTP status.
    case httpStatus(code: Int, body: String)
    /// Response body could not be decoded into the expected shape.
    case decodingFailed(String)
    /// Request body could not be encoded.
    case encodingFailed(String)
    /// No API key was provided in the configuration.
    case missingAPIKey
    /// Networking failed before a response was received.
    case transport(String)
    /// The requested capability is not supported by this provider.
    case unsupported(String)
    /// Provider returned a structured error payload.
    case provider(message: String)
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "LLM HTTP \(code): \(body)"
        case .decodingFailed(let detail):
            return "LLM response decoding failed: \(detail)"
        case .encodingFailed(let detail):
            return "LLM request encoding failed: \(detail)"
        case .missingAPIKey:
            return "LLM provider configuration is missing an API key"
        case .transport(let detail):
            return "LLM transport error: \(detail)"
        case .unsupported(let detail):
            return "Unsupported LLM operation: \(detail)"
        case .provider(let message):
            return "LLM provider error: \(message)"
        }
    }
}
