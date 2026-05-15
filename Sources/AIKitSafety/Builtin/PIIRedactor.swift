import Foundation
import AIKitCapability

/// Blocks tool calls whose JSON input contains obvious PII patterns, unless
/// the tool is explicitly tagged as accepting PII.
public struct PIIRedactor: Guardrail {
    public let id = "builtin.piiRedactor"
    public let stages: Set<Verifier.Stage> = [.preToolUse]
    private let acceptsPII: Set<String>

    /// - Parameter acceptsPII: tool names allowed to receive PII.
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

    public func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        guard case .preToolUse(let call) = payload else { return .pass }
        if acceptsPII.contains(call.name) { return .pass }

        let haystack = call.input.allStrings.joined(separator: " ")
        let range = NSRange(haystack.startIndex..., in: haystack)
        for (kind, regex) in Self.patterns
        where regex.firstMatch(in: haystack, range: range) != nil {
            return .block(reason: "Tool input to '\(call.name)' appears to contain \(kind) PII.")
        }
        return .pass
    }
}
