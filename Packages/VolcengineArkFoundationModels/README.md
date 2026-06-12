# VolcengineArkFoundationModels

A Foundation Models **provider package** for Volcengine Ark (Doubao) chat
completions: `VolcengineArkLanguageModel` is an official
`FoundationModels.LanguageModel` conformance, and its executor streams true
SSE deltas into the official generation channel. Hand the model to a
`LanguageModelSession` and everything else — tool calling, guided generation,
streaming, transcript management — is the system implementation.

```swift
import FoundationModels
import VolcengineArkFoundationModels

let model = VolcengineArkLanguageModel(
    configuration: .init(apiKey: key, model: "doubao-seed-2-0-lite-260215"),
    capabilities: LanguageModelCapabilities(
        capabilities: [.toolCalling, .reasoning, .guidedGeneration])
)
let session = LanguageModelSession(model: model, tools: tools, instructions: "…")
let reply = try await session.respond(to: "…")
```

## Best practices

- **Declare capabilities honestly, and declare `.guidedGeneration` if you use
  it.** Foundation Models gates `respond(generating:)` on the model's
  declared `LanguageModelCapabilities` and fails *before any network call*.
  The package default is `[.toolCalling, .reasoning]`; add
  `.guidedGeneration` for models that honor `response_format`.
- **The host owns the API key.** The package never reads environment
  variables. An empty key throws `VolcengineArkError.missingAPIKey` at
  request time.
- **Vendor extensions go through `defaultExtraBody`**, a
  `[String: GeneratedContent]` merged into the request JSON at the wire.
  The package defaults pin thinking off:

  ```swift
  var extraBody = VolcengineArkConfiguration.defaultWireExtraBody
  // ["thinking": {"type":"disabled"}, "reasoning_effort": "minimal"]
  extraBody["parallel_tool_calls"] = GeneratedContent(true)
  let configuration = VolcengineArkConfiguration(
      apiKey: key, model: id, defaultExtraBody: extraBody)
  ```

  Reserved keys (`model`, `messages`, `tools`, `temperature`, `max_tokens`,
  `stream`, `stream_options`, and `response_format` when a schema is active)
  cannot be overridden.
- **Reasoning is driven by the official API, not extras.** A request's
  `ContextOptions.reasoningLevel` overrides the wire defaults: `.light` /
  `.moderate` / `.deep` map to Ark `reasoning_effort` `low`/`medium`/`high`
  with thinking enabled; `.custom(value)` passes the value through.
- **Tool-calling mode maps to `tool_choice`.**
  `GenerationOptions.toolCallingMode` `.required` → `"required"` (the model
  emits *only* tool calls — the lever for single-purpose routing stages),
  `.disallowed` → `"none"`, `.allowed`/nil → Ark's default `"auto"`.
- **Guided generation maps to `response_format`.** A request `schema`
  becomes Ark's strict `json_schema` constraint, embedding the
  `GenerationSchema`'s official JSON encoding.

## Error taxonomy

Where the official taxonomy has a counterpart, the package throws it, so
session-side handling works without knowing the provider:

| Failure | Thrown as |
| --- | --- |
| HTTP 429 | `LanguageModelError.rateLimited` |
| Transport timeout | `LanguageModelError.timeout` |
| Cancellation | `CancellationError` (clean stream stop; partial usage still reported) |
| Other HTTP statuses, encoding, missing key, transport, bad endpoint | `VolcengineArkError` |

## Observability

- `VolcengineArkUsageMonitor.setHandler { event in … }` — per-request token
  usage (official channel `Usage` currency) plus wall-clock duration. The
  session surface does not expose provider usage; install this for billing
  or metrics. Process-wide; handler runs synchronously, keep it cheap.
- `VolcengineArkWireTrace.setHandler { … }` *(DEBUG builds only)* — the exact
  request body and every raw SSE line, for wire-level debugging.

## Behavior notes

- The generation channel has **no stop event**; the OpenAI-compatible finish
  reason rides response-entry metadata as `"finishReason"`.
- Prior `.reasoning` transcript entries are **never replayed to the wire** —
  chat-completions backends expect reasoning not to be re-sent; the entries
  stay in the Foundation Models transcript for the host.
- Image attachments in user prompts become OpenAI-style `image_url` parts
  carrying the attachment URL verbatim (remote or `data:`); an attachment
  label of `low`/`high`/`auto` becomes the `detail` hint.
- Usage may arrive across several trailing SSE chunks; the channel sees one
  final `updateUsage` with the best numbers (reasoning tokens estimated from
  streamed text only when the wire never reports them).
