import Foundation
import FoundationModels
import AIToolKit
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
        memory: [UsageEvent],
        transcript: [TranscriptEntry],
        toolManifest: [ToolDescriptor],
        model: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        toolCallFallbackHint: Bool = false,
        workflowPlanningHint: Bool = false,
        leanWorkflowSchemaHint: Bool = true
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
        // The built-in `reportFailure` escape hatch passes regardless: the
        // orchestrator provides it by default, so contexts never list it.
        var tools = toolManifest.filter {
            context.toolNames.contains($0.name)
                || $0.name == ReportFailureTool.toolName
        }

        if workflowPlanningHint, !tools.isEmpty {
            systemParts.append(WorkflowPromptBuilder.planningInstruction(
                toolManifest: tools,
                minimal: leanWorkflowSchemaHint,
                includeExample: true
            ))
            tools = [WorkflowSchema.descriptor(
                availableTools: tools, minimal: leanWorkflowSchemaHint
            )]
        } else if toolCallFallbackHint, !tools.isEmpty {
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

    private static func recentActionsBlock(_ memory: [UsageEvent]) -> String? {
        guard !memory.isEmpty else { return nil }
        let lines = memory
            .sorted { $0.timestamp < $1.timestamp }
            .map { "- [\($0.kind.rawValue)] \($0.payloadText)" }
            .joined(separator: "\n")
        return "<recent-actions>\n\(lines)\n</recent-actions>"
    }
}
