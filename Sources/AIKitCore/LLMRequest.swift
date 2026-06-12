import Foundation
import FoundationModels
import AIToolKit

/// A stateless request to an LLM provider. Carries no memory or retry policy.
///
/// Provider-specific wire configuration (reasoning effort, thinking switches,
/// vendor body extensions) is owned by the provider package, not this request:
/// AIKit describes *what* to generate — messages, tools, and an optional
/// `responseSchema` — and each provider maps that onto its own transport.
public struct LLMRequest: Sendable, Hashable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var tools: [ToolDescriptor]
    public var temperature: Double?
    public var maxTokens: Int?
    /// Constrains the response to one JSON value matching this schema
    /// (FoundationModels guided generation). Apple-backed providers pass it to
    /// `LanguageModelSession.respond(to:schema:)`; OpenAI-compatible providers
    /// map it to a `response_format` JSON-schema constraint. Providers that
    /// support neither ignore it and return freeform text.
    public var responseSchema: GenerationSchema?

    public init(
        model: String,
        system: String? = nil,
        messages: [Message] = [],
        tools: [ToolDescriptor] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        responseSchema: GenerationSchema? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.responseSchema = responseSchema
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model &&
        lhs.system == rhs.system &&
        lhs.messages == rhs.messages &&
        lhs.tools.map(\.aikitHashSignature) == rhs.tools.map(\.aikitHashSignature) &&
        lhs.temperature == rhs.temperature &&
        lhs.maxTokens == rhs.maxTokens &&
        lhs.responseSchema.aikitSchemaSignature == rhs.responseSchema.aikitSchemaSignature
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(model)
        hasher.combine(system)
        hasher.combine(messages)
        hasher.combine(tools.map(\.aikitHashSignature))
        hasher.combine(temperature)
        hasher.combine(maxTokens)
        hasher.combine(responseSchema.aikitSchemaSignature)
    }
}

private struct ToolDescriptorHashSignature: Sendable, Hashable {
    var name: String
    var description: String
    var argumentsSchema: String
    var outputSchema: String?
}

private extension ToolDescriptor {
    var aikitHashSignature: ToolDescriptorHashSignature {
        let argumentsJSON = (try? argumentsSchema.jsonString())
            ?? argumentsSchema.debugDescription
        let outputJSON: String?
        if let outputSchema {
            outputJSON = (try? outputSchema.jsonString()) ?? outputSchema.debugDescription
        } else {
            outputJSON = nil
        }
        return ToolDescriptorHashSignature(
            name: name,
            description: description,
            argumentsSchema: argumentsJSON,
            outputSchema: outputJSON
        )
    }
}

private extension GenerationSchema? {
    var aikitSchemaSignature: String? {
        guard let schema = self else { return nil }
        return (try? schema.jsonString()) ?? schema.debugDescription
    }
}

/// The product of `PromptBuilder`: an `LLMRequest` plus a human-readable summary
/// used for guardrail inspection and event emission.
public struct RenderedPrompt: Sendable, Hashable {
    public var request: LLMRequest
    public var toolNames: Set<String>

    public init(request: LLMRequest, toolNames: Set<String>) {
        self.request = request
        self.toolNames = toolNames
    }

    /// The full system prompt as the model will see it.
    public var systemPrompt: String { request.system ?? "" }

    /// The most recent user instruction in the request, if any.
    public var latestUserText: String? {
        request.messages.last { $0.role == .user }?.plainText
    }
}
