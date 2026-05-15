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

    public static func build(
        instruction: String,
        context: ResolvedContext,
        memory: [UsageEvent],
        transcript: [TranscriptEntry],
        toolManifest: [ToolDescriptor],
        model: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil
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
        let tools = context.toolNames.isEmpty
            ? toolManifest
            : toolManifest.filter { context.toolNames.contains($0.name) }

        return LLMRequest(
            model: model,
            system: systemParts.joined(separator: "\n\n"),
            messages: messages,
            tools: tools,
            temperature: temperature,
            maxTokens: maxTokens
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
