import Foundation
import FoundationModels
import AIToolKit

/// A stateless request to an LLM provider. Carries no memory or retry policy.
public struct LLMRequest: Sendable, Hashable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var tools: [ToolDescriptor]
    public var temperature: Double?
    public var maxTokens: Int?
    /// Requests generated voice/audio output from providers that support it.
    /// Providers that do not support audio output throw `LLMError.unsupported`.
    public var audioOutput: AudioOutputOptions?
    /// Provider-specific knobs merged into the request body. Use this for
    /// provider extensions and overrides (`thinking`, `top_p`, `seed`, `stop`,
    /// …). Reserved keys owned by the wire encoder (`model`, `messages`,
    /// `stream`, …) are never overwritten by these values.
    public var extraBody: [String: GeneratedContent]

    public init(
        model: String,
        system: String? = nil,
        messages: [Message] = [],
        tools: [ToolDescriptor] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        audioOutput: AudioOutputOptions? = nil,
        extraBody: [String: GeneratedContent] = [:]
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.audioOutput = audioOutput
        self.extraBody = extraBody
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model &&
        lhs.system == rhs.system &&
        lhs.messages == rhs.messages &&
        lhs.tools.map(\.aikitHashSignature) == rhs.tools.map(\.aikitHashSignature) &&
        lhs.temperature == rhs.temperature &&
        lhs.maxTokens == rhs.maxTokens &&
        lhs.audioOutput == rhs.audioOutput &&
        lhs.extraBody.aikitGeneratedContentSignature == rhs.extraBody.aikitGeneratedContentSignature
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(model)
        hasher.combine(system)
        hasher.combine(messages)
        hasher.combine(tools.map(\.aikitHashSignature))
        hasher.combine(temperature)
        hasher.combine(maxTokens)
        hasher.combine(audioOutput)
        hasher.combine(extraBody.aikitGeneratedContentSignature)
    }
}

private struct ToolDescriptorHashSignature: Sendable, Hashable {
    var name: String
    var description: String
    var argumentsSchema: String
    var outputSchema: String?
    var annotations: ToolAnnotations?
    var argumentExamples: [String]?
}

private struct GeneratedContentHashSignature: Sendable, Hashable {
    var key: String
    var json: String
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
            outputSchema: outputJSON,
            annotations: annotations,
            argumentExamples: argumentExamples?.map(\.jsonString)
        )
    }
}

private extension Dictionary where Key == String, Value == GeneratedContent {
    var aikitGeneratedContentSignature: [GeneratedContentHashSignature] {
        map { GeneratedContentHashSignature(key: $0.key, json: $0.value.jsonString) }
            .sorted { lhs, rhs in lhs.key < rhs.key }
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
