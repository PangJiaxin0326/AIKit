import Foundation

/// A stateless request to an LLM provider. Carries no memory or retry policy.
public struct LLMRequest: Sendable, Hashable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var tools: [ToolDescriptor]
    public var temperature: Double?
    public var maxTokens: Int?
    /// Provider-specific knobs merged into the request body. Local models need
    /// these (`num_ctx`, `keep_alive`, `stop`, `top_p`, `seed`, …). Reserved
    /// keys owned by the wire encoder (`model`, `messages`, `stream`, …) are
    /// never overwritten by these values.
    public var extraBody: [String: JSONValue]

    public init(
        model: String,
        system: String? = nil,
        messages: [Message] = [],
        tools: [ToolDescriptor] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        extraBody: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extraBody = extraBody
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
