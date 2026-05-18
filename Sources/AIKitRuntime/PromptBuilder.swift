import Foundation
import AIKitCore
import AIKitCapability

/// Pure function turning resolved context + memory + transcript into an
/// `LLMRequest`. No I/O, no state.
public enum PromptBuilder {
    /// The AIKit base preamble, prepended to every system prompt.
    public static let basePreamble = """
    You are an AI agent embedded in an application. Use the provided tools to \
    take actions on the user's behalf. Prefer a tool call over a guess. When \
    the task is complete, reply with a concise final answer and no tool calls.
    """

    /// Appended when `toolCallFallbackHint` is set and tools are available.
    /// Models without native function calling (common for local models) can
    /// still drive tools by emitting this fenced block, which `OutputParser`
    /// recovers. Models with native tool support ignore it.
    public static let toolFallbackInstruction = """
    If you cannot emit a native tool call, request a tool by writing a fenced \
    code block tagged `tool` containing a single JSON object: \
    {"name": "<toolName>", "input": { ... }}. Emit nothing after that block.
    """

    public static func build(
        instruction: String,
        context: ResolvedContext,
        memory: [UsageEvent],
        transcript: [TranscriptEntry],
        toolManifest: [ToolDescriptor],
        model: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        extraBody: [String: JSONValue] = [:],
        toolCallFallbackHint: Bool = false
    ) -> LLMRequest {
        var systemParts = [basePreamble]
        if !context.systemPromptFragment.isEmpty {
            systemParts.append(context.systemPromptFragment)
        }
        if let recent = recentActionsBlock(memory) {
            systemParts.append(recent)
        }

        var messages: [Message] = []
        messages.append(Message(role: .user, text: instruction))
        messages.append(contentsOf: transcript.map(\.message))

        // Tools restricted to the view's subset (the manifest is already
        // filtered by the registry, but be defensive about empty subsets).
        let tools = toolManifest.filter { context.toolNames.contains($0.name) }

        if toolCallFallbackHint, !tools.isEmpty {
            systemParts.append(toolFallbackInstruction)
        }

        return LLMRequest(
            model: model,
            system: systemParts.joined(separator: "\n\n"),
            messages: messages,
            tools: tools,
            temperature: temperature,
            maxTokens: maxTokens,
            extraBody: extraBody
        )
    }

    private static func recentActionsBlock(_ memory: [UsageEvent]) -> String? {
        guard !memory.isEmpty else { return nil }
        let lines = memory
            .sorted { $0.timestamp < $1.timestamp }
            .map { "- [\($0.kind.rawValue)] \($0.payloadText)" }
            .joined(separator: "\n")
        return "<recent-actions>\n\(lines)\n</recent-actions>"
    }
}
