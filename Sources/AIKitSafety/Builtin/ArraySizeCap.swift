import Foundation
import FoundationModels

/// Blocks a tool output that would feed the model an array with more than
/// `maxItems` elements. Oversized lists bloat the context window, blow past
/// the model's effective attention, and invite hallucinated summaries — so an
/// over-long collection is stopped before it reaches the LLM rather than
/// silently truncated.
///
/// Tool outputs are the one payload that flows *into* the model from outside
/// (the prompt is host-authored; tool-call arguments are the model's own
/// output), so this rides the `postToolUse` stage — the same hook that lets a
/// block stop the turn before the model can build on the output. The scan is
/// recursive: an oversized array nested anywhere inside a structured result
/// trips it.
///
/// Enforcement is error-driven, like every guardrail: a violation surfaces as
/// the official `LanguageModelError.guardrailViolation`. A tool that
/// legitimately returns long lists should page them — or sit in `exempt`.
public struct ArraySizeCap: Guardrail {
    public let id = "builtin.arraySizeCap"
    public let stages: Set<GuardrailStage> = [.postToolUse]
    private let maxItems: Int
    private let exempt: Set<String>

    /// - Parameters:
    ///   - maxItems: the largest array (in items) allowed through. An array of
    ///     exactly `maxItems` passes; one item more blocks. Default 10.
    ///   - exempt: tool names whose outputs skip the check.
    public init(maxItems: Int = 10, exempt: Set<String> = []) {
        self.maxItems = maxItems
        self.exempt = exempt
    }

    public func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
        guard case .postToolUse(let call, let output) = payload else { return .pass }
        if exempt.contains(call.toolName) { return .pass }

        for segment in output.segments {
            guard case .structure(let structured) = segment else { continue }
            if let count = Self.largestArray(in: structured.content), count > maxItems {
                return .block(
                    reason: "Tool '\(call.toolName)' returned an array of \(count) items, over the \(maxItems)-item cap."
                )
            }
        }
        return .pass
    }

    // MARK: - Detection

    /// The largest array count found anywhere in the content tree, or `nil`
    /// when it holds no arrays. Walks nested structures and arrays so an
    /// over-long list buried inside an object still trips the cap.
    private static func largestArray(in content: GeneratedContent) -> Int? {
        switch content.kind {
        case .array(let values):
            return values.reduce(values.count) { max($0, largestArray(in: $1) ?? 0) }
        case .structure(let properties, _):
            return properties.values.compactMap(largestArray).max()
        case .null, .bool, .number, .string:
            return nil
        @unknown default:
            return nil
        }
    }
}
