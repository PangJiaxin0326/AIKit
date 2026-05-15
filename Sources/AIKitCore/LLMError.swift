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
    /// The request exceeded its configured timeout. Retriable.
    case timeout(String)
    /// The request was cancelled by the caller. Never retriable.
    case cancelled
    /// The requested capability is not supported by this provider.
    case unsupported(String)
    /// Provider returned a structured error payload.
    case provider(message: String)
}

extension LLMError {
    /// Maps a transport-layer error into the right `LLMError` case so retry
    /// classification stays accurate instead of collapsing everything to a
    /// generic transient string.
    public static func from(transport error: any Error) -> LLMError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timeout(urlError.localizedDescription)
            case .badURL, .unsupportedURL:
                return .unsupported(urlError.localizedDescription)
            default:
                return .transport("\(urlError.code.rawValue): \(urlError.localizedDescription)")
            }
        }
        return .transport(error.localizedDescription)
    }
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
        case .timeout(let detail):
            return "LLM request timed out: \(detail)"
        case .cancelled:
            return "LLM request was cancelled"
        case .unsupported(let detail):
            return "Unsupported LLM operation: \(detail)"
        case .provider(let message):
            return "LLM provider error: \(message)"
        }
    }
}
