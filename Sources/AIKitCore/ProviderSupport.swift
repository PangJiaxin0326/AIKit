import Foundation
import FoundationModels
import AIToolKit

package enum AIKitProviderDefaults {
    package static let appleIntelligenceBaseURL = URL(string: "aikit-apple-intelligence://local")!
    package static let appleIntelligenceModelListURL = URL(
        string: "aikit-apple-intelligence://local/models"
    )!
    package static let privateCloudComputeBaseURL = URL(
        string: "aikit-apple-intelligence://private-cloud-compute"
    )!

    package static let arkBaseURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
    package static let arkModelListURL = URL(
        string: "https://ark.cn-beijing.volces.com/api/v3/models"
    )!
    package static let arkChatCompletionsPath = "chat/completions"
    package static let arkChatCompletionsURL = URL(
        string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    )!
}

package enum AIKitModelListNormalizer {
    package static func uniquePreservingOrder(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }

    package static func uniqueSorted(_ models: [String]) -> [String] {
        uniquePreservingOrder(models).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    package static func replacingAvailableModels(
        _ models: [String],
        currentDefaultModel: String?
    ) -> (models: [String], defaultModel: String?) {
        let normalized = uniquePreservingOrder(models)
        guard let currentDefaultModel, normalized.contains(currentDefaultModel) else {
            return (normalized, nil)
        }
        return (normalized, currentDefaultModel)
    }
}

package enum AIKitMalformedToolInput {
    private static let rawKey = "__aikit_malformed_tool_input_raw"

    package static func make(raw: String) -> GeneratedContent {
        .object([rawKey: .string(raw)])
    }

    package static func raw(in arguments: GeneratedContent) -> String? {
        guard case .structure(let object, _) = arguments.kind,
              object.count == 1
        else { return nil }
        if case .string(let raw)? = object[rawKey]?.kind {
            return raw
        }
        return nil
    }
}

func validatedProviderData(
    for request: URLRequest,
    session: URLSession
) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch {
        throw LLMError.from(transport: error)
    }
    try validateProviderHTTPResponse(response, data: data)
    return data
}

func validatedProviderBytes(
    for request: URLRequest,
    session: URLSession
) async throws -> URLSession.AsyncBytes {
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
        (bytes, response) = try await session.bytes(for: request)
    } catch {
        throw LLMError.from(transport: error)
    }
    try validateProviderHTTPResponse(response, data: Data())
    return bytes
}

func validateProviderHTTPResponse(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw LLMError.httpStatus(code: http.statusCode, body: body)
    }
}
