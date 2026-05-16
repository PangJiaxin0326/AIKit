import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// `LLMProvider` backed by Apple's on-device Foundation Models framework.
///
/// This provider is intentionally text-first. Foundation Models exposes its
/// own native `Tool` protocol, but AIKit tools already flow through
/// `ToolRegistry`; reporting `supportsNativeTools == false` enables AIKit's
/// fenced-```tool``` fallback so the runtime can continue to dispatch tools
/// through the registry without a second adapter layer.
public struct AppleIntelligenceProvider: LLMProvider {
    public static let defaultModel = "apple-intelligence"

    public let defaultModel: String

    public var supportsNativeTools: Bool { false }

    public init(model: String = Self.defaultModel) {
        self.defaultModel = model
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return try await AppleFoundationModels.complete(request)
        }
        throw LLMError.unsupported(
            "Apple Intelligence requires the Foundation Models framework on iOS 26, macOS 26, or visionOS 26."
        )
        #else
        throw LLMError.unsupported(
            "Apple Intelligence requires the Foundation Models framework."
        )
        #endif
    }

    public func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty {
                        continuation.yield(.textDelta(response.text))
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
            case .toolUse(_, let name, let input):
                return "Requested tool \(name) with input \(jsonString(input))."
            case .toolResult(_, let content, let isError):
                return isError ? "Tool error: \(content)" : "Tool result: \(content)"
            }
        }
        .joined(separator: "\n")
    }

    private static func toolManifestBlock(_ tools: [ToolDescriptor]) -> String? {
        guard !tools.isEmpty else { return nil }
        let lines = tools.map { descriptor in
            """
            - \(descriptor.name): \(descriptor.description)
              input schema: \(jsonString(descriptor.inputSchema))
            """
        }
        .joined(separator: "\n")
        return """
        Available AIKit tools:
        \(lines)
        """
    }

    private static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? value.data(),
              let string = String(data: data, encoding: .utf8)
        else {
            return "\(value)"
        }
        return string
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private enum AppleFoundationModels {
    static func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LLMError.provider(
                message: "Apple Intelligence is unavailable: \(model.availability)"
            )
        }

        let rendered = AppleIntelligenceProvider.renderedPrompt(for: request)
        let session: LanguageModelSession
        if let instructions = rendered.instructions {
            session = LanguageModelSession(instructions: instructions)
        } else {
            session = LanguageModelSession()
        }
        let options = GenerationOptions(
            sampling: nil,
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens
        )

        do {
            let response = try await session.respond(
                to: rendered.prompt,
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
#endif

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
