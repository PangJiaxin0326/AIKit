import Foundation
import FoundationModels
import AIToolKit

/// `LLMProvider` backed by Apple's Foundation Models — the on-device system
/// model or Private Cloud Compute.
///
/// A thin shim over `LanguageModelProvider`: requests ride the official
/// `LanguageModel` executor path (`Transcript` in, generation-channel events
/// out), so tool calls, guided generation, and streaming all use the system
/// implementations instead of hand-rolled prompt flattening.
public struct AppleIntelligenceProvider: LLMProvider {
    public enum Endpoint: String, Sendable, Hashable, Codable, CaseIterable {
        case onDevice = "apple-intelligence"
        case privateCloudCompute = "private-cloud-compute"

        init?(modelID: String) {
            switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case Self.onDevice.rawValue:
                self = .onDevice
            case Self.privateCloudCompute.rawValue:
                self = .privateCloudCompute
            default:
                return nil
            }
        }
    }

    public var providerName: String {
        AIKitProviderKind.appleIntelligence.definition.displayName
    }

    public let configuration: LLMProviderConfiguration
    public let endpoint: Endpoint

    /// Foundation Models executes tool calls natively on both endpoints via
    /// the executor path, so the runtime never needs the fenced-```tool```
    /// fallback here.
    public var supportsNativeTools: Bool { true }

    public init(
        endpoint: Endpoint = .onDevice,
        model: String? = nil,
        availableModels: [String] = [],
        timeout: TimeInterval? = nil
    ) {
        self.endpoint = endpoint
        self.configuration = LLMProviderConfiguration(
            apiKey: "",
            baseURL: endpoint == .privateCloudCompute
                ? AIKitProviderDefaults.privateCloudComputeBaseURL
                : AIKitProviderDefaults.appleIntelligenceBaseURL,
            defaultModel: model ?? endpoint.rawValue,
            availableModels: availableModels.isEmpty
                ? Self.defaultModels
                : availableModels,
            timeout: timeout
        )
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        switch resolvedEndpoint(for: request) {
        case .onDevice:
            return try await onDeviceAdapter().complete(request)
        case .privateCloudCompute:
            do {
                return try await privateCloudComputeAdapter().complete(request)
            } catch let error as LLMError where Self.isNetworkFailure(error) {
                // Private Cloud Compute degrades to the on-device model when
                // the network is unreachable.
                return try await onDeviceAdapter().complete(request)
            }
        }
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        switch resolvedEndpoint(for: request) {
        case .onDevice:
            return onDeviceAdapter().stream(request)
        case .privateCloudCompute:
            return privateCloudComputeStream(request)
        }
    }

    private static let defaultModels = Endpoint.allCases.map(\.rawValue)

    private func resolvedEndpoint(for request: LLMRequest) -> Endpoint {
        Endpoint(modelID: request.model) ?? endpoint
    }

    // MARK: - Adapters

    private func onDeviceAdapter() -> LanguageModelProvider<SystemLanguageModel> {
        LanguageModelProvider(
            configuration: configuration,
            providerName: providerName,
            makeModel: { _ in SystemLanguageModel.default },
            makeExecutor: { model in
                guard model.isAvailable else {
                    throw LLMError.provider(
                        message: "Apple Intelligence is unavailable: \(model.availability)"
                    )
                }
                return SystemLanguageModel.Executor(
                    configuration: model.executorConfiguration
                )
            }
        )
    }

    private func privateCloudComputeAdapter()
        -> LanguageModelProvider<PrivateCloudComputeLanguageModel> {
        LanguageModelProvider(
            configuration: configuration,
            providerName: providerName,
            makeModel: { _ in PrivateCloudComputeLanguageModel() },
            makeExecutor: { model in
                guard model.isAvailable else {
                    throw LLMError.provider(
                        message: "Private Cloud Compute is unavailable: \(model.availability)"
                    )
                }
                return PrivateCloudComputeLanguageModel.Executor(
                    configuration: model.executorConfiguration
                )
            },
            mapError: { error in
                if case PrivateCloudComputeLanguageModel.Error.networkFailure = error {
                    return .transport(Self.networkFailureDetail)
                }
                return nil
            }
        )
    }

    /// Streams from Private Cloud Compute, restarting on-device when the
    /// network fails before any output was produced.
    private func privateCloudComputeStream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var yieldedAny = false
                do {
                    for try await chunk in privateCloudComputeAdapter().stream(request) {
                        yieldedAny = true
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch let error as LLMError
                    where Self.isNetworkFailure(error) && !yieldedAny {
                    do {
                        for try await chunk in onDeviceAdapter().stream(request) {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - PCC network-failure marker

    private static let networkFailureDetail = "private-cloud-compute-network-failure"

    private static func isNetworkFailure(_ error: LLMError) -> Bool {
        if case .transport(let detail) = error {
            return detail == networkFailureDetail
        }
        return false
    }
}
