import Foundation
import AIKitCore
import AIKitCapability

/// Guards tool calls whose JSON input contains obvious PII patterns, unless
/// the tool is explicitly tagged as accepting PII.
///
/// Two modes:
/// - `.block` (default) — refuses the call outright.
/// - `.redact` — rewrites the matched substrings to a placeholder and lets the
///   (now-sanitized) call proceed. This is the only built-in rail that uses
///   the payload-rewrite hook.
public struct PIIRedactor: Guardrail {
    public enum Mode: Sendable {
        case block
        case redact(placeholder: String)

        public static let redact = Mode.redact(placeholder: "[REDACTED]")
    }

    public let id = "builtin.piiRedactor"
    public let stages: Set<Verifier.Stage> = [.preToolUse]
    private let acceptsPII: Set<String>
    private let mode: Mode

    /// - Parameters:
    ///   - acceptsPII: tool names allowed to receive PII untouched.
    ///   - mode: block the call (default) or redact and continue.
    public init(acceptsPII: Set<String> = [], mode: Mode = .block) {
        self.acceptsPII = acceptsPII
        self.mode = mode
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

    public func rewrite(_ payload: GuardrailPayload) async -> GuardrailPayload? {
        guard case .redact(let placeholder) = mode,
              case .preToolUse(let call) = payload,
              !acceptsPII.contains(call.name)
        else { return nil }

        let redacted = Self.redactStrings(in: call.input, placeholder: placeholder)
        guard redacted != call.input else { return nil }
        var rewritten = call
        rewritten.input = redacted
        return .preToolUse(rewritten)
    }

    public func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        guard case .preToolUse(let call) = payload else { return .pass }
        if acceptsPII.contains(call.name) { return .pass }

        let kinds = Self.matchedKinds(in: call.input)
        guard let kind = kinds.first else { return .pass }

        switch mode {
        case .block:
            return .block(reason: "Tool input to '\(call.name)' appears to contain \(kind) PII.")
        case .redact:
            // `rewrite` already ran; anything still matching here couldn't be
            // sanitized, so fall back to blocking rather than leaking it.
            return .block(
                reason: "Tool input to '\(call.name)' still contains \(kind) PII after redaction."
            )
        }
    }

    // MARK: - Detection / rewriting

    private static func matchedKinds(in value: JSONValue) -> [String] {
        let haystack = value.allStrings.joined(separator: " ")
        guard !haystack.isEmpty else { return [] }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return patterns.compactMap { kind, regex in
            regex.firstMatch(in: haystack, range: range) != nil ? kind : nil
        }
    }

    private static func redactStrings(
        in value: JSONValue,
        placeholder: String
    ) -> JSONValue {
        switch value {
        case .string(let string):
            return .string(redact(string, placeholder: placeholder))
        case .array(let values):
            return .array(values.map { redactStrings(in: $0, placeholder: placeholder) })
        case .object(let object):
            return .object(object.mapValues { redactStrings(in: $0, placeholder: placeholder) })
        case .null, .bool, .number:
            return value
        }
    }

    private static func redact(_ string: String, placeholder: String) -> String {
        let template = NSRegularExpression.escapedTemplate(for: placeholder)
        var result = string
        for (_, regex) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: template
            )
        }
        return result
    }
}
