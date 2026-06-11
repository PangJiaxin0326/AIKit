# Foundation Models Replacement Opportunities

This inventory is scoped to AIKit after AIToolKit adopted Foundation Models'
`Tool`, `GenerationSchema`, and `GeneratedContent` model. It intentionally does
not propose custom tool adapters in AIKit and does not require changes to
AIToolKit.

## Adopted in AIKit

| Area | Foundation Models API | Status | Notes |
| --- | --- | --- | --- |
| Capability tools | `FoundationModels.Tool` | Adopted | Built-in capability tools conform directly to `Tool`; AIKit no longer owns a custom tool protocol. |
| Tool arguments and outputs | `GeneratedContent` | Adopted | Runtime, safety, providers, and tests now pass tool arguments/results as `GeneratedContent` at AIKit boundaries. |
| Tool schemas | `GenerationSchema` | Adopted | Tool descriptors carry `argumentsSchema` and optional `outputSchema` from Foundation Models/AIToolKit. |
| Structured workflow parsing | `GeneratedContent` initializers | Adopted | Runtime parsing now feeds workflow plans/bindings through AIToolKit's `GeneratedContent` contracts instead of Codable JSON wrappers. |
| Provider wire conversion | `GeneratedContent` / `GenerationSchema` at boundary | Adopted | Ark conversion stays provider-local because the HTTP wire format is still JSON; this is not a tool adapter. |

## Candidate Replacements

| AIKit surface | Foundation Models replacement candidate | Recommendation | Reasoning |
| --- | --- | --- | --- |
| `AppleIntelligenceProvider` prompt and tool manifest rendering | `LanguageModelSession` with native Foundation Models tools | Candidate | Useful if AIKit lets the Apple provider own the actual `Tool` instances. The current runtime owns a registry plus descriptors, so native execution would require a runtime ownership change rather than an adapter. |
| `PromptBuilder` transcript/message assembly for Apple-local models | Foundation Models session transcript APIs | Candidate | The generic provider abstraction still needs portable messages for Ark, but Apple-only paths could avoid manual manifest prose. |
| `OutputParser` fenced JSON tool/workflow fallback | Native generated output/tool calling | Candidate for native providers only | Keep fallback for non-native providers and weak models. Remove it only on paths that are guaranteed to return typed Foundation Models output. |
| Runtime structured response schema plumbing | `GenerationSchema` response schemas | Candidate | AIKit already carries schemas as `GenerationSchema`; provider-specific `response_format` JSON should remain only at provider wire boundaries. |
| Configuration tool full payloads | `@Generable` DTOs | Candidate | `AIKitConfiguration` itself is not `Generable`. Split generated DTOs only if hosts need typed model-authored configuration objects; otherwise `GeneratedContent` is simpler. |
| Safety redaction over generated values | `GeneratedContent` tree traversal | Adopted, possible polish | The redactor now rewrites `GeneratedContent`. Further validation can lean on `Generable` decode failures where a typed contract exists. |
| Multimodal prompt attachments | Foundation Models prompt attachment APIs | Candidate | Keep AIKit `ImageContent`/`AudioContent` while supporting non-Apple providers. Add a direct Apple-provider path only where Foundation Models supports the same media shape. |
| Session usage and activity tracing | Foundation Models session telemetry | Candidate | AIKit's cross-provider usage history remains valuable. Provider-native telemetry can augment it, not replace it, unless AIKit drops cross-provider support. |

## Not Recommended

| Idea | Reason |
| --- | --- |
| Reintroduce an AIKit custom `Tool` wrapper around Foundation Models `Tool` | Violates the package direction and adds an adapter layer the user explicitly rejected. |
| Move AIToolKit workflow schema/value algebra back into AIKit | AIToolKit is the owner of workflow contracts; AIKit should consume its Foundation Models-backed surface. |
| Replace provider-local HTTP JSON models with `GeneratedContent` everywhere | Ark and other wire protocols still require explicit request/response types for correctness, streaming deltas, errors, and media handling. |
| Remove fenced/fallback parsing globally | Non-native providers still need text fallback behavior, and the two-round workflow guidance relies on robust freeform JSON extraction. |

## Follow-Up Checks

- Revisit native Apple tool execution only if AIKit changes `ToolRegistry` ownership so the provider can receive concrete `Tool` values without an adapter.
- Keep JSON serialization confined to provider wire boundaries and persistence surfaces.
- Prefer `Generable` structs for new built-in tool input/output types; use raw `GeneratedContent` only for dynamic payloads such as configuration snapshots.
