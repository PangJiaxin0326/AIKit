import Foundation
import FoundationModels
import AIToolKit
import AIKitCore
import AIKitCapability

/// Pure function turning resolved context + transcript into an
/// `LLMRequest`. No I/O, no state.
///
/// Each turn's request carries ONLY that turn's own iterations (the
/// `transcript` parameter). Earlier turns' tool calls and replies are never
/// injected — turns are independent by construction; durable memory is
/// reachable only through the explicit `searchMemory` tool.
public enum PromptBuilder {
    /// The AIKit base preamble, prepended to every system prompt.
    public static let basePreamble = """
    You are an AI agent embedded in an application. Use the provided tools to \
    take actions on the user's behalf. Prefer a tool call over a guess. When \
    the task is complete, reply with a concise final answer and no tool calls.
    """

    /// Appended when `toolCallFallbackHint` is set and tools are available.
    /// Text-only provider paths can still drive tools by emitting this fenced
    /// block, which `OutputParser` recovers. Models with native tool support
    /// ignore it.
    public static let toolFallbackInstruction = """
    If you cannot emit a native tool call, request a tool by writing a fenced \
    code block tagged `tool` containing a single JSON object: \
    {"name": "<toolName>", "arguments": { ... }}. Emit nothing after that block.
    """

    public static func build(
        instruction: String,
        context: ResolvedContext,
        transcript: [TranscriptEntry],
        toolManifest: [ToolDescriptor],
        model: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        toolCallFallbackHint: Bool = false
    ) -> LLMRequest {
        var systemParts = [basePreamble]
        if !context.systemPromptFragment.isEmpty {
            systemParts.append(context.systemPromptFragment)
        }

        var messages: [Message] = []
        messages.append(Message(role: .user, text: instruction))
        messages.append(contentsOf: transcript.map(\.message))

        // Tools restricted to the view's subset (the manifest is already
        // filtered by the orchestrator, but be defensive about empty subsets).
        // The built-in `reportFailure` escape hatch passes regardless: the
        // orchestrator provides it by default, so contexts never list it.
        let tools = toolManifest.filter {
            context.toolNames.contains($0.name)
                || $0.name == ReportFailureTool.toolName
        }

        if toolCallFallbackHint, !tools.isEmpty {
            systemParts.append(toolFallbackInstruction)
        }

        return LLMRequest(
            model: model,
            system: systemParts.joined(separator: "\n\n"),
            messages: messages,
            tools: tools,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }
}
