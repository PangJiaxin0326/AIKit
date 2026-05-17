import Foundation
import AIKitCore

/// Built-in tool the model calls to bail out of a request it cannot
/// confidently complete (too vague, ambiguous, or out of scope). The
/// `Orchestrator` intercepts it by name and ends the turn in a failure
/// state carrying `reason`, so it never actually runs `invoke`.
public struct ReportFailureTool: Tool {
    public struct Input: Codable, Sendable {
        public var reason: String
        public init(reason: String) { self.reason = reason }
    }

    public struct Output: Codable, Sendable {
        public var acknowledged: Bool
        public init(acknowledged: Bool = true) { self.acknowledged = acknowledged }
    }

    public static let name = "reportFailure"
    public static let description = """
        Call this instead of guessing when you cannot confidently complete the \
        user's request — e.g. it is too vague or ambiguous, asks for something \
        outside your tools, or you would have to invent details. Give a short, \
        plain reason the user can act on (what is unclear or missing). Do not \
        call any other tool in the same turn.
        """
    public static let schema = ToolSchema.object(
        properties: [
            "reason": .string(description: "Why you can't confidently proceed"),
        ],
        required: ["reason"]
    )

    public init() {}

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        Output()
    }
}
