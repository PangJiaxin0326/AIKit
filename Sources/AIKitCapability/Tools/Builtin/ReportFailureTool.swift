import Foundation
import FoundationModels
import AIToolKit
import AIKitCore

/// Built-in tool the model calls to bail out of a request it cannot
/// confidently complete (too vague, ambiguous, or out of scope). The
/// `Orchestrator` intercepts it by name and ends the turn in a failure
/// state carrying `reason`, so it never actually runs `invoke`.
public struct ReportFailureTool: Tool {
    @Generable
    public struct Input: Codable, Sendable {
        @Guide(description: "Why you can't confidently proceed")
        public var reason: String
        public init(reason: String) { self.reason = reason }
    }

    @Generable
    public struct Output: Codable, Sendable {
        public var acknowledged: Bool
        public init(acknowledged: Bool = true) { self.acknowledged = acknowledged }
    }

    public static let toolName = "reportFailure"
    public static let toolDescription = """
        Call this instead of guessing when you cannot confidently complete the \
        user's request — e.g. it is too vague or ambiguous, asks for something \
        outside your tools, or you would have to invent details. Give a short, \
        plain reason the user can act on (what is unclear or missing). Do not \
        call any other tool in the same turn.
        """
    public var name: String { Self.toolName }
    public var description: String { Self.toolDescription }

    public init() {}

    public func call(arguments input: Input) async throws -> Output {
        Output()
    }
}
