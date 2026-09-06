import Foundation
import AIKitCore

/// Fetches the selectable model ids per provider: Apple Intelligence is the
/// fixed pair of endpoints; Ark serves an OpenAI-style `GET /models`.
public struct AIKitModelCatalog: AIKitModelCatalogFetching {
    private struct ListedModels: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    package static let arkModelListURL = URL(
        string: "https://ark.cn-beijing.volces.com/api/v3/models"
    )!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchModels(
        for provider: AIKitProviderKind,
        apiKey: String = "",
        timeout: TimeInterval? = nil
    ) async throws -> [String] {
        switch provider {
        case .appleIntelligence:
            return AIKitModelListNormalizer.uniqueSorted(
                provider.definition.staticModelIDs
            )
        case .ark:
            let request = try makeArkRequest(apiKey: apiKey, timeout: timeout)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw AIKitModelCatalogError.transport(String(describing: error))
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw AIKitModelCatalogError.httpStatus(
                    code: http.statusCode,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            }
            do {
                let listed = try JSONDecoder().decode(ListedModels.self, from: data)
                return AIKitModelListNormalizer.uniqueSorted(listed.data.map(\.id))
            } catch {
                throw AIKitModelCatalogError.decodingFailed(String(describing: error))
            }
        }
    }

    private func makeArkRequest(
        apiKey: String,
        timeout: TimeInterval?
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.arkModelListURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout {
            request.timeoutInterval = timeout
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIKitModelCatalogError.missingAPIKey
        }
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}

