import Foundation
import FoundationModels
import AIToolKit

/// Blocks tool calls whose arguments contain obvious PII patterns, unless the
/// tool is explicitly tagged as accepting PII.
///
/// Enforcement is error-driven, like every guardrail: a match blocks the call
/// before it executes (surfaced by the engine as the official
/// `LanguageModelError.guardrailViolation`). The old redact-and-continue mode
/// went away with the payload-rewrite hook — the official session hooks can
/// veto a call but not alter it. A tool that legitimately receives PII goes
/// in `acceptsPII`; a tool that must accept partial PII sanitizes inside its
/// own `call`.
public struct PIIGuard: Guardrail {
    public let id = "builtin.piiGuard"
    public let stages: Set<GuardrailStage> = [.preToolUse]
    private let acceptsPII: Set<String>

    /// - Parameter acceptsPII: tool names allowed to receive PII untouched.
    public init(acceptsPII: Set<String> = []) {
        self.acceptsPII = acceptsPII
    }

    private static let patterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String)] = [
            ("email", #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#),
            ("phone", #"(?<!\d)(\+?\d[\d \-().]{8,}\d)(?!\d)"#),
            ("ssn", #"\b\d{3}-\d{2}-\d{4}\b"#),
            ("card", #"\b(?:\d[ -]*?){13,16}\b"#),
        ]
        return specs.compactMap { name, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
                .map { (name, $0) }
        }
    }()

    public func evaluate(_ payload: GuardrailPayload) async -> GuardrailOutcome {
        guard case .preToolUse(let call) = payload else { return .pass }
        if acceptsPII.contains(call.toolName) { return .pass }

        guard let kind = Self.matchedKinds(in: call.arguments).first else {
            return .pass
        }
        return .block(
            reason: "Tool input to '\(call.toolName)' appears to contain \(kind) PII."
        )
    }

    // MARK: - Detection

    /// Detection runs per string scalar — a pattern that only matches across
    /// two joined fields is not PII in either field.
    private static func matchedKinds(in value: GeneratedContent) -> [String] {
        let strings = value.allStrings.filter { !$0.isEmpty }
        guard !strings.isEmpty else { return [] }
        return patterns.compactMap { kind, regex in
            let hit = strings.contains { string in
                let range = NSRange(string.startIndex..., in: string)
                return regex.firstMatch(in: string, range: range) != nil
            }
            return hit ? kind : nil
        }
    }
}
