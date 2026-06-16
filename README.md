# AIKit

An app-embedded AI agent runtime over Apple's Foundation Models protocol
API. Every turn runs in one official `LanguageModelSession`, built as a
`DynamicProfile` over any official `LanguageModel` — Apple's on-device
model, Private Cloud Compute, or the bundled Volcengine Ark provider — and
AIKit contributes what the session API does not: per-screen context and
tool scoping, error-driven guardrails, durable memory and usage records,
retry/deadline policy, and host-facing event/activity streams plus SwiftUI
surfaces.

Swift 6, strict concurrency, language mode v6. No third-party dependencies.

| Module | Role |
| --- | --- |
| `AIKitCore`       | Shipped models (`AIKitLanguageModel`), provider catalog & credentials |
| `AIKitCapability` | View contexts, durable memory, usage records, built-in tools, configuration |
| `AIKitSafety`     | Guardrails: `PolicyEngine`, the `.guardrails(_:)` profile modifier, built-in rails |
| `AIKitRuntime`    | The `Orchestrator`: one official session per turn, events, retries, deadlines |
| `AIKitUI`         | Configuration dashboard, floating assistant overlay, view-context modifiers |
| `AIKit`           | Umbrella re-exporting all of the above plus AIToolKit and the Ark provider |

## Quick start

```swift
import AIKit

// 1. A model — any official LanguageModel works; these are the shipped ones.
let model = try AIKitLanguageModel.resolve(
    provider: .ark, modelID: "doubao-seed-2-0-lite-260215", apiKey: key)
// or: .appleIntelligence, .privateCloudCompute

// 2. Tools — ordinary FoundationModels tools. `reportFailure` rides along
// automatically as the model's bail-out for unexecutable asks.
let tools: [any Tool] = [NavigateTool { input in
    .init(navigated: router.go(to: input.destination))
}]

// 3. Context, guardrails, memory.
let resolver = ContextResolver()
let guardrails = PolicyEngine(rails: [
    AllowlistedTools(allowed: ["navigate"]),
    PIIGuard(),
    InjectionSniffer(),
])
let orchestrator = Orchestrator(
    model: model,
    tools: tools,
    memory: try SwiftDataMemoryStore(path: storeURL.path),
    contextResolver: resolver,
    guardrails: guardrails,
    usageRecorder: SwiftDataSessionUsageStore(modelContainer: container)
)

// 4. One call per user instruction; events stream back.
for try await event in await orchestrator.run("Open my profile") {
    switch event {
    case .llmDelta(let delta):        render(delta)
    case .toolCall(let call):         showBusy("Calling \(call.toolName)…")
    case .toolResult(let call, let output): log(call.toolName, output.contentText)
    case .finalAnswer(let text):      present(text)
    case .failure(let reason):        presentRefusal(reason)   // reportFailure
    case .error(let error):           presentError(error)
    default: break
    }
}
```

## View contexts (per-screen prompt + tool scoping)

Each screen pushes a `ViewContext` — a system-prompt fragment, a tool-name
subset, and metadata — while it is visible; the orchestrator merges the
stack per turn, so the model only ever sees the tools the current UI
affords. In SwiftUI:

```swift
ContentView()
    .aiContextResolver(resolver)            // once, at the root

ProfileScreen()
    .aiContext(ViewContext(
        id: .init("profile"),
        displayName: "Profile",
        systemPromptFragment: "The user is viewing their profile.",
        toolNames: ["navigate", "setProfileField"]
    ))
```

A context with no tools stays pure chat. Turns are independent by
construction — a fresh session per turn, no history injection; durable
memory is reachable only through the explicit `searchMemory` tool.

## Guardrails (error-driven, inside the session)

Guardrails run at four stages. The tool stages ride the official
`DynamicProfile` hooks *inside* the session machinery — no tool wrapping —
and a block throws the official `LanguageModelError.guardrailViolation`
(rail id, stage, and reason in its `metadata`), the same error shape
`SystemLanguageModel.Guardrails` surfaces:

| Stage | Where it runs | Payload |
| --- | --- | --- |
| `prePrompt`   | host-side, before the session exists | `RenderedPrompt` |
| `preToolUse`  | `onToolCall`, **before the tool executes** — a block prevents execution | `Transcript.ToolCall` |
| `postToolUse` | `onToolOutput`, on the executed call's output | `Transcript.ToolCall` + `Transcript.ToolOutput` |
| `finalResult` | host-side, on the turn's final text | `String` |

Built-in rails: `AllowlistedTools`, `PIIGuard` (block-only; tag tools that
legitimately receive PII via `acceptsPII`), `InjectionSniffer` (warns by
default), `OutputLengthCap`, `ArraySizeCap` (blocks a tool output that would
feed the model an array of more than 10 items — recursive, configurable
`maxItems`, with an `exempt` tool set). Custom rails conform to `Guardrail`
(`id`, `stages`, `evaluate`) and register on the `PolicyEngine` —
`register`/`replace`/`unregister` work at runtime.

For sessions you build yourself (e.g. an AIToolKit `WorkflowProfile`),
apply the same engine with one modifier so every tool call passes the same
global policies:

```swift
let session = LanguageModelSession(profile:
    LanguageModelSession.Profile { Instructions(text); tools }
        .model(model)
        .guardrails(engine)
)
```

Note: a `preToolUse` block surfaces from `respond` wrapped in the official
`LanguageModelSession.ToolCallError` — match `underlyingError`.

## Errors, retries, deadlines

- Typed errors only: the official `LanguageModelError` taxonomy (429 →
  `.rateLimited`, timeouts → `.timeout`, blocks → `.guardrailViolation`),
  `ToolError`, `CancellationError`, and provider shapes like
  `VolcengineArkError`.
- `Orchestrator.Options.retry` (`RetryPolicy`) reruns a turn in a fresh
  session for transient failures and retriable tool errors. Model-authored
  garbage that fails a strict typed decode (`GeneratedContent.ParsingError`)
  is retriable — the fresh attempt lets the model re-emit correct
  arguments. Guardrail violations never retry.
- Tools that want *in-session* self-correction should catch their own
  validation problems and return descriptive error strings; a thrown tool
  error aborts the attempt (official `ToolCallError`) and is handled by the
  turn-level retry policy.
- `Options.maxTurnDuration` is a hard wall-clock cap racing every blocking
  await in the turn (`TurnDeadlineExceeded` on overrun).

## Activity, external work, usage

- `orchestrator.activityUpdates()` streams `OrchestratorActivity` — live
  busy state, the most user-visible phase across overlapping turns, per-task
  snapshots with token usage, and a sticky failure reason for UI.
- Host-run work (e.g. a workflow session) joins the same stream:
  `beginExternalWork(statusText:onCancel:)` / `updateExternalWork` /
  `endExternalWork`; `cancelActiveTurns()` reaches it too.
- Pass a `SwiftDataSessionUsageStore` as `usageRecorder` and every turn
  lands a durable `AIKitSessionUsageRecord` (model, provider, duration,
  round trips, token usage, outcome: completed / failed / cancelled /
  refused).

## Configuration & UI

- `AIKitConfigurationStore` (actor) holds the user-facing
  Core/Capability/Runtime/Safety configuration;
  `AIKitConfigurationTools.all(store:)` exposes it to the model as
  `getAIKitConfiguration` / `setAIKitConfiguration` tools, with an audit
  trail of changes.
- `AIKitView` renders the configuration dashboard (provider, models, tools,
  guardrail toggles).
- `AIKitChatbotOverlay(orchestrator:mode:)` is the floating assistant entry
  point — `.assistant` (glass capsule, text + voice input, long-press
  detail) or `.voice` (hands-free loop). Voice transcription comes from
  MultiModalKit's SpeechAnalyzer-backed service.

## Testing

`AIKitTestSupport` ships `MockLanguageModel` — a scripted official
`LanguageModel` whose executor replays turns through the real generation
channel (text, reasoning, tool calls, usage), so tests exercise the same
native session loop as production, with no network. Tests use Swift
Testing; score agent behavior by side effects on your stores, never by the
model's prose.

## Multi-step agents

For select-then-work workflows (typed tool selection, host-stopped work
stage), use AIToolKit's `WorkflowProfile` — see the AIToolKit README for
the recipe, the measured traps, and the cost model. Bracket the run with
`beginExternalWork`/`endExternalWork` so AIKit's assistant UI reflects it.
