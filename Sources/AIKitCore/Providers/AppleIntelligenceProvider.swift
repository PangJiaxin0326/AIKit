import Foundation
import FoundationModels
import AIToolKit

/// `LLMProvider` backed by Apple's on-device Foundation Models framework.
///
/// This provider is intentionally text-first. Although AIKit tools conform to
/// Foundation Models' `Tool` protocol, the runtime owns and dispatches them
/// itself; reporting `supportsNativeTools == false` enables the
/// fenced-```tool``` fallback on this provider path.
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

    public var supportsNativeTools: Bool { false }

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
        if request.audioOutput != nil {
            throw LLMError.unsupported(
                "AppleIntelligenceProvider does not support generated audio output."
            )
        }
        return try await AppleFoundationModels.complete(
            request,
            endpoint: Endpoint(modelID: request.model) ?? endpoint
        )
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    for block in response.content {
                        switch block {
                        case .text(let text):
                            if !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                        case .reasoning(let text):
                            if !text.isEmpty {
                                continuation.yield(.reasoningDelta(text))
                            }
                        case .image:
                            break
                        case .audio(let audio):
                            continuation.yield(.audio(audio))
                        case .toolUse(let id, let name, let arguments):
                            continuation.yield(.toolUseStart(id: id, name: name))
                            let data = arguments.data()
                            if let json = String(data: data, encoding: .utf8) {
                                continuation.yield(.toolUseInputDelta(id: id, json: json))
                            }
                            continuation.yield(.toolUseStop(id: id))
                        case .toolResult:
                            break
                        }
                    }
                    continuation.yield(.usage(response.usage))
                    continuation.yield(.stop(response.stopReason))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.provider(
                        message: error.localizedDescription
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let defaultModels = Endpoint.allCases.map(\.rawValue)

    struct RenderedPrompt: Sendable, Hashable {
        var instructions: String?
        var prompt: String
    }

    static func renderedPrompt(for request: LLMRequest) -> RenderedPrompt {
        var instructionParts: [String] = []
        if let system = request.system?.trimmedNonEmpty {
            instructionParts.append(system)
        }

        var promptParts: [String] = []
        for message in request.messages {
            switch message.role {
            case .system:
                if let text = renderedText(for: message).trimmedNonEmpty {
                    instructionParts.append(text)
                }
            case .user:
                append(message, label: "User", to: &promptParts)
            case .assistant:
                append(message, label: "Assistant", to: &promptParts)
            case .tool:
                append(message, label: "Tool", to: &promptParts)
            }
        }

        if let manifest = toolManifestBlock(request.tools) {
            instructionParts.append(manifest)
        }

        return RenderedPrompt(
            instructions: instructionParts.joined(separator: "\n\n").trimmedNonEmpty,
            prompt: promptParts.joined(separator: "\n\n").trimmedNonEmpty ?? ""
        )
    }

    private static func append(
        _ message: Message,
        label: String,
        to promptParts: inout [String]
    ) {
        guard let text = renderedText(for: message).trimmedNonEmpty else { return }
        promptParts.append("\(label):\n\(text)")
    }

    private static func renderedText(for message: Message) -> String {
        message.content.compactMap { block in
            switch block {
            case .text(let text):
                return text
            case .reasoning:
                return nil
            case .image(let image):
                return "Image attachment: \(image.source.description)."
            case .audio(let audio):
                var parts = ["Audio attachment: \(audio.source.description)."]
                if let transcript = audio.transcript, !transcript.isEmpty {
                    parts.append("Transcript: \(transcript)")
                }
                return parts.joined(separator: " ")
            case .toolUse(_, let name, let arguments):
                return "Requested tool \(name) with input \(arguments.jsonString)."
            case .toolResult(_, let content, let isError):
                return isError ? "Tool error: \(content)" : "Tool result: \(content)"
            }
        }
        .joined(separator: "\n")
    }

    private static func toolManifestBlock(_ tools: [ToolDescriptor]) -> String? {
        guard !tools.isEmpty else { return nil }
        let lines = tools.map { descriptor in
            let schema = (try? descriptor.argumentsSchema.jsonString()) ?? "{}"
            return """
            - \(descriptor.name): \(descriptor.description)
              input schema: \(schema)
            """
        }
        .joined(separator: "\n")
        return """
        Available AIKit tools:
        \(lines)
        """
    }

}

private enum AppleFoundationModels {
    static func complete(
        _ request: LLMRequest,
        endpoint: AppleIntelligenceProvider.Endpoint
    ) async throws -> LLMResponse {
        if endpoint == .privateCloudCompute {
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
                do {
                    return try await completeWithPrivateCloudCompute(request)
                } catch PrivateCloudComputeLanguageModel.Error.networkFailure(_) {
                    return try await completeOnDevice(request)
                } catch {
                    throw LLMError.provider(message: error.localizedDescription)
                }
            }
        }
        return try await completeOnDevice(request)
    }

    private static func completeOnDevice(_ request: LLMRequest) async throws -> LLMResponse {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LLMError.provider(
                message: "Apple Intelligence is unavailable: \(model.availability)"
            )
        }
        let rendered = AppleIntelligenceProvider.renderedPrompt(for: request)
        let session = makeSession(model: model, rendered: rendered, request: request)
        return try await respond(session: session, prompt: rendered.prompt, request: request)
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private static func completeWithPrivateCloudCompute(
        _ request: LLMRequest
    ) async throws -> LLMResponse {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            throw LLMError.provider(
                message: "Private Cloud Compute is unavailable: \(model.availability)"
            )
        }
        let rendered = AppleIntelligenceProvider.renderedPrompt(for: request)
        let session = makeProfileSession(model: model, rendered: rendered, request: request)
        return try await respond(session: session, prompt: rendered.prompt, request: request)
    }

    /// Builds the per-request session. On OS 27 the session is declared with
    /// the official `DynamicProfile` DSL (instructions + generation knobs as
    /// profile modifiers); earlier systems fall back to the plain initializer
    /// and pass the knobs per call instead.
    private static func makeSession(
        model: SystemLanguageModel,
        rendered: AppleIntelligenceProvider.RenderedPrompt,
        request: LLMRequest
    ) -> LanguageModelSession {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            return makeProfileSession(model: model, rendered: rendered, request: request)
        }
        if let instructions = rendered.instructions {
            return LanguageModelSession(model: model, instructions: instructions)
        }
        return LanguageModelSession(model: model)
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private static func makeProfileSession(
        model: some LanguageModel,
        rendered: AppleIntelligenceProvider.RenderedPrompt,
        request: LLMRequest
    ) -> LanguageModelSession {
        let profile = LanguageModelSession.Profile {
            if let instructions = rendered.instructions {
                Instructions(instructions)
            }
        }
        .model(model)
        .temperature(request.temperature)
        .maximumResponseTokens(request.maxTokens)
        return LanguageModelSession(profile: profile)
    }

    private static func respond(
        session: LanguageModelSession,
        prompt: String,
        request: LLMRequest
    ) async throws -> LLMResponse {
        let options = GenerationOptions(
            samplingMode: nil,
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens
        )

        do {
            // A response schema rides Foundation Models guided generation, the
            // official structured-output path; the constrained JSON value is
            // returned to the runtime as text.
            if let schema = request.responseSchema {
                let response = try await session.respond(
                    to: prompt,
                    schema: schema,
                    options: options
                )
                return LLMResponse(
                    content: [.text(response.content.jsonString)],
                    stopReason: .endTurn
                )
            }
            let response = try await session.respond(
                to: prompt,
                options: options
            )
            return LLMResponse(
                content: [.text(response.content)],
                stopReason: .endTurn
            )
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.provider(message: error.localizedDescription)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
