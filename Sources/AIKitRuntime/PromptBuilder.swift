import Foundation
import AIKitCapability
import AIKitSafety

/// Pure function turning the resolved view context into the session's
/// instructions. No I/O, no state.
///
/// Each turn runs in a fresh `LanguageModelSession`, so a turn carries only
/// its own tool rounds (the session's transcript). Earlier turns' tool calls
/// and replies are never injected — turns are independent by construction;
/// durable memory is reachable only through the explicit `searchMemory` tool.
public enum PromptBuilder {
    /// The AIKit base preamble, prepended to every system prompt.
    public static let basePreamble = """
    You are an AI agent embedded in an application. Use the provided tools to \
    take actions on the user's behalf. Prefer a tool call over a guess. When \
    the task is complete, reply with a concise final answer and no tool calls.
    """

    /// The full instructions string for one turn: the base preamble plus the
    /// resolved context's system-prompt fragment.
    public static func instructions(for context: ResolvedContext) -> String {
        var parts = [basePreamble]
        if !context.systemPromptFragment.isEmpty {
            parts.append(context.systemPromptFragment)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The prompt snapshot guardrails inspect and `promptBuilt` reports.
    public static func render(
        instruction: String,
        context: ResolvedContext
    ) -> RenderedPrompt {
        RenderedPrompt(
            instructions: instructions(for: context),
            userPrompt: instruction,
            toolNames: context.toolNames
        )
    }
}
