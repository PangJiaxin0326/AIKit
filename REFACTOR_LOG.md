# AIKit Refactor Decision Log

Date: 2026-05-18

## Objective

Run a full review and refactor loop over the repository, using reviewer,
evaluator, implementer, and verifier agents. Apply only valuable, minimal-scope
changes, repeat until no valuable refactors remain, and record the decisions.

## Agent Loop

1. Reviewer agents inspected the package for subtle bugs, risky code,
   redundancy, API drift, and missing tests.
2. Evaluator agents reviewed each proposed change for value, risk, API impact,
   and test requirements.
3. Implementer agents applied accepted changes in scoped batches:
   tool/platform/UI drift, provider parsing, and runtime retry transcripts.
4. Verifier agents reviewed the final diff and test evidence.
5. A second review/evaluation/implementation pass fixed the remaining
   multi-tool transcript bug and restored umbrella import coverage.
6. Final verifier result: pass, with no valuable minimal-scope refactors left.

## Decisions

| Area | Decision | Rationale | Result |
| --- | --- | --- | --- |
| Package platforms | Change | `GUIDE.md` specifies iOS 17, macOS 14, visionOS 1, but the manifest used 26.5 minimums. | `Package.swift` and `README.md` now match the guide. |
| Empty tool manifest | Change | Empty `ViewContext.toolNames` should expose no tools, not every registered tool. | `ToolRegistry.manifest(for: [])` returns no tools; `registeredDescriptors()` is the explicit all-tools API. |
| Empty allowlist | Change | An empty allowlist passing every tool was a safety footgun. | `AllowlistedTools(allowed: [])` now blocks all tool calls. |
| Prompt tool filtering | Change | PromptBuilder should not re-expand an empty context to all tools. | Tool filtering now only uses explicit context tool names. |
| AIKitView orchestrator initializer | Change | The initializer stored an orchestrator but did not use it. | `AIKitView(orchestrator:)` now applies the chatbot overlay; dashboard-only init is unchanged. |
| Liquid Glass platform fallback | Change | Lowering platform minimums required avoiding unconditional iOS/macOS/visionOS 26 UI APIs. | Added an availability-gated `glassEffect` fallback. |
| OpenAI streaming tool deltas | Change | Later streaming tool-call chunks may omit `type`; decoding them strictly dropped argument chunks. | OpenAI streamed argument-only deltas are preserved and tested. |
| Anthropic streaming tool IDs | Change | Input/stop chunks used numeric indexes instead of provider tool IDs. | Anthropic stream chunks now correlate through an index-to-tool-id map. |
| Malformed native/streamed tool JSON | Change | Invalid tool JSON was collapsed to `{}`, which could execute tools with fabricated input. | Malformed tool input is preserved with an internal sentinel and becomes `ParserError.malformedToolInput`. |
| Correction prompts | Change | Retry corrections were encoded as orphan tool messages. | Corrections now use provider-valid user guidance. |
| Tool decoding failures | Change | Bad model tool-input shapes were treated as fatal. | `ToolRegistryError.decodingFailed` now classifies as malformed output for corrective retry. |
| Failed tool results | Change | Failed tools skipped post-tool guardrails and transcript error results. | Failed tool output is verified with `isError: true`, emitted, recorded, and rethrown for retry classification. |
| Blocked failed-tool output | Change | A blocked post-tool error payload must not still be emitted. | Guardrail blocks now abort before emitting/recording the failed tool result. |
| Multi-tool retry transcript | Change | If one tool in a batch failed, later unexecuted tool calls could remain unmatched in the transcript. | Remaining calls are recorded as skipped error tool results before retry/fallback. |
| Activity observer lifecycle | Change | Register/unregister ordering could leave a stale continuation after early termination. | Added a small early-termination guard. |
| Umbrella import coverage | Change | Integration tests stopped proving `import AIKit` re-exports the public surface. | Integration tests again use `import AIKit`. |
| Ollama streaming synthesis | No change | Native Ollama emits complete tool calls and existing behavior was intentional. | No code change. |

## Tests Added Or Updated

- Package manifest platform check.
- Empty manifest and explicit all-tools descriptor tests.
- Empty context prompt filtering test.
- Empty allowlist blocking test.
- OpenAI streaming argument-only delta reconstruction test.
- Anthropic two-tool stream ID correlation test.
- Malformed native tool-input parser test.
- Malformed native tool input retry without invoking the tool.
- Malformed streamed tool JSON does not invoke no-input tools.
- Tool decoding failure retry with provider-valid transcript.
- Retriable tool failure error-result transcript test.
- Post-tool guardrail `isError: true` test.
- Post-tool guardrail block suppresses failed-result emission test.
- Multi-tool batch failure records skipped results for unexecuted calls.
- Integration suite restored to `import AIKit` umbrella coverage.

## Verification

- Baseline before changes: `swift test` passed 85 tests.
- Targeted runtime gate: `swift test --filter OrchestratorTests` passed 12 tests.
- Final full gate: `swift test` passed 101 tests in 22 suites.
- Diff hygiene: `git diff --check` passed.
- Final verifier agent verdict: pass, no remaining valuable minimal-scope
  refactors.

## Migration Notes

- `ToolRegistry.manifest(for: [])` now means "no tools." Use
  `registeredDescriptors()` when the caller explicitly needs every registered
  tool descriptor, such as configuration UI.
- `TranscriptEntry` has a new `correctiveGuidance(String)` case. Downstream
  exhaustive switches over this public enum will need to handle it.
