import Foundation

public enum AIKitProviderKind: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case ollama = "Ollama"
    case other = "Other"

    public var id: String { rawValue }

    public init?(providerName: String) {
        switch providerName.normalizedProviderName {
        case "openai":
            self = .openAI
        case "anthropic", "claude":
            self = .anthropic
        case "ollama":
            self = .ollama
        case "other", "custom":
            self = .other
        default:
            return nil
        }
    }

}

public struct AIKitModelCatalog: Sendable {
    private struct ListedModels: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private struct OllamaTags: Decodable {
        struct Model: Decodable {
            let name: String?
            let model: String?
        }

        let models: [Model]
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchModels(
        for provider: AIKitProviderKind,
        baseURL: URL? = nil,
        apiKey: String = "",
        timeout: TimeInterval? = nil
    ) async throws -> [String] {
        let request = try makeRequest(
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            timeout: timeout
        )
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.from(transport: error)
        }
        try validate(response, data: data)
        do {
            return try decodeModels(provider: provider, data: data)
        } catch {
            throw LLMError.decodingFailed(String(describing: error))
        }
    }

    private func makeRequest(
        provider: AIKitProviderKind,
        baseURL: URL?,
        apiKey: String,
        timeout: TimeInterval?
    ) throws -> URLRequest {
        var request = URLRequest(url: try modelListURL(provider: provider, baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout {
            request.timeoutInterval = timeout
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .openAI:
            guard !trimmedKey.isEmpty else { throw LLMError.missingAPIKey }
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            guard !trimmedKey.isEmpty else { throw LLMError.missingAPIKey }
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .ollama:
            break
        case .other:
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
        }

        return request
    }

    private func modelListURL(
        provider: AIKitProviderKind,
        baseURL: URL?
    ) throws -> URL {
        switch provider {
        case .openAI:
            return OpenAIProvider.defaultBaseURL.appending(path: "v1/models")
        case .anthropic:
            return try AnthropicProvider.defaultBaseURL.resolvingEndpoint(
                apiPrefix: "v1",
                endpoint: "models"
            )
        case .ollama:
            return try (baseURL ?? OllamaProvider.defaultBaseURL).resolvingEndpoint(
                apiPrefix: "api",
                endpoint: "tags"
            )
        case .other:
            guard let baseURL else {
                throw LLMError.unsupported("Other provider needs a base URL to list models.")
            }
            return try baseURL.resolvingEndpoint(apiPrefix: "v1", endpoint: "models")
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpStatus(code: http.statusCode, body: body)
        }
    }

    private func decodeModels(provider: AIKitProviderKind, data: Data) throws -> [String] {
        switch provider {
        case .openAI, .anthropic, .other:
            let response = try JSONDecoder().decode(ListedModels.self, from: data)
            return uniqueSorted(response.data.map(\.id))
        case .ollama:
            let response = try JSONDecoder().decode(OllamaTags.self, from: data)
            return uniqueSorted(response.models.compactMap { $0.name ?? $0.model })
        }
    }

    private func uniqueSorted(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            unique.append(trimmed)
        }
        return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private extension String {
    var normalizedProviderName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
