# AIKit

App-embedded AI agent support over Apple's Foundation Models framework.
The official `LanguageModelSession` is the execution engine and source of
truth: a `DynamicProfile` owns the model, instructions, tools, and
generation configuration, and the session runs the tool loop, owns the
transcript, streams the response, and reports usage. AIKit contributes only
what the framework does not: error-driven guardrails on the official
lifecycle hooks, optional retry/deadline/concurrency policies, durable
memory and usage records, cross-session activity aggregation, per-screen
context scoping, and SwiftUI surfaces.

Swift 6.4, strict concurrency, language mode v6. No third-party dependencies.

| Module | Role |
| --- | --- |
| `AIKitCore`       | Provider metadata, secure credential persistence interfaces, transcript text projections |
| `AIKitProviders`  | Optional shipped-model construction (`AIKitLanguageModel`), Ark catalog transport and retry classification |
| `AIKitCapability` | View contexts, durable memory, usage records, built-in tools, configuration |
| `AIKitSafety`     | Guardrails: `PolicyEngine`, the `.guardrails(_:)` profile modifier, built-in rails, warning sinks |
| `AIKitRuntime`    | `AIKitConversation` + `AIKitTurnPolicy` (host policies around one official session), `AIKitActivityStore`, the refusal escape hatch — and the deprecated `Orchestrator` |
| `AIKitUI`         | Configuration dashboard, floating assistant overlay, `AIKitConversationPresenter`, view-context modifiers |
| `AIKit`           | Umbrella re-exporting all of the above plus AIToolKit and the Ark provider |

## Quick start — the direct path

Most callers need no AIKit runtime type at all. Build a profile, make a
session, respond:

```swift
import AIKit

// 1. A model — any official LanguageModel works; these are the shipped ones.
let model = try AIKitLanguageModel.resolve(
    provider: .ark, modelID: "doubao-seed-2-0-lite-260215", apiKey: key)
// or: .appleIntelligence, .privateCloudCompute

// 2. A profile: instructions + tools + model + generation configuration +
// guardrails, all declared in one place.
let engine = PolicyEngine(rails: [PIIGuard(), InjectionSniffer()])
// Open a model existential at a generic boundary so the profile remains
// concrete when sent into the session (important under Swift 6 isolation).
func makeSession(
    model: some LanguageModel,
    tools: [any Tool],
    engine: PolicyEngine
) -> LanguageModelSession {
    let profile = LanguageModelSession.Profile {
        Instructions("Assist the user.")
        tools + [ReportFailureTool()]
    }
    .model(model)
    .temperature(0.2)
    .refusalEscapeHatch()
    .guardrails(engine)
    return LanguageModelSession(profile: profile)
}

// 3. One official session per conversation or independent task.
let session = makeSession(model: model.base, tools: tools, engine: engine)
let response = try await session.respond(to: "Open my profile")
```

The transcript (`session.transcript`), busy state (`session.isResponding`),
streaming (`session.streamResponse`), and usage (`session.usage`) are all
read straight off the session — AIKit does not mirror them.

## AIKitConversation — optional host policies

When a conversation needs retry, a wall-clock deadline, explicit overlap
handling, or durable usage records, wrap the session in the one host
boundary AIKit provides:

```swift
let conversation = AIKitConversation(
    session: session,
    turnPolicy: .init(
        retry: .never,            // default: tools may have external effects
        deadline: 30,             // cooperative execution budget, including backoff
        overlap: .serialize       // or .reject → AIKitConversationError
    ),
    usageRecorder: SwiftDataSessionUsageStore(modelContainer: container),
    usageLabels: .init(modelID: model.modelID, providerName: "Volcengine Ark"),
    activity: activityStore,      // optional global busy aggregation
    activityLabel: "Filing…"
)

let turn = try await conversation.respond(to: "File this note")
turn.content            // the official response text
turn.transcriptEntries  // the turn's official entries
turn.usage              // the official response usage
```

Facts worth knowing:

- One session per conversation: sequential turns share the transcript;
  rehydrate a persisted conversation with
  `LanguageModelSession(profile:history:)`.
- The conversation sets transcript error handling explicitly. Its default
  `.revertTranscript` restores failed history, but cannot undo tool effects.
- Automatic retry is disabled by default. Choose `.default` or a custom retry
  policy only when every tool and the host operation are safe to repeat.
  Guardrail violations and `TurnRefusal` never retry. With `.preserveTranscript`,
  automatic retry also requires `prepareForRetry` to repair history/state.
- Text, typed `generating:`, schema responses, and `collectResponse` all use
  `withTurn`. Official responses are Sendable when their content is Sendable;
  `AIKitTurnResponse` is now a deprecated typealias.
- `withTurn` is the policy boundary for other official SDK operations. Direct
  session calls bypass it. The old `markTurnStart`/`recordTurn` pair accounts
  usage only and is not a substitute for admission or cancellation.
- `collectResponse` consumes the official stream but releases only the accepted
  result. Native snapshots can precede a final guardrail rejection. Hosts
  deliberately showing provisional text can consume the native stream inside
  `withTurn`, accepting that disclosure contract and disabling automatic retry.
- Failed and cancelled turns record consumed tokens. Essential settlement uses
  async defer with a narrow cancellation shield, then releases the turn slot.
- Deadlines start after FIFO admission and include generation and backoff. The
  runtime cancels overdue work and waits for cooperative cleanup; a tool that
  ignores cancellation can delay settlement. Queueing and persistence are
  outside the execution budget. A cancelled queue waiter exits independently.

## Guardrails (error-driven, inside the session)

Guardrails run at four stages, all riding the official `DynamicProfile`
lifecycle hooks — no tool wrapping. A block throws the official
`LanguageModelError.guardrailViolation` (rail id, stage, and reason in its
`metadata`), the same error shape `SystemLanguageModel.Guardrails`
surfaces:

| Stage | Where it runs | Payload |
| --- | --- | --- |
| `prePrompt`   | `onPrompt`, **before generation** — a block never reaches the model | `RenderedPrompt` preserves the official multimodal prompt; resolved instruction/tool context is optional |
| `preToolUse`  | `onToolCall`, **before the tool executes** — a block prevents execution | `Transcript.ToolCall` |
| `postToolUse` | `onToolOutput`, on the executed call's output | `Transcript.ToolCall` + `Transcript.ToolOutput` |
| `finalResult` | `onResponse`, on each **non-empty** response entry, including intermediate prose beside tool calls | `String` |

```swift
let profile = LanguageModelSession.Profile { Instructions(text); tools }
    .model(model)
    .refusalEscapeHatch()   // BEFORE .guardrails — hooks run in application
                            // order, so a strict allowlist cannot block the
                            // reportFailure bail-out
    .guardrails(
        engine,
        promptContext: .init(instructions: text, toolNames: names),
        activity: activityStore   // warnings go here, never the transcript
    )
```

Built-in rails: `AllowlistedTools`, `PIIGuard` (block-only; tag tools that
legitimately receive PII via `acceptsPII`), `InjectionSniffer` (warns by
default), `OutputLengthCap`, `ArraySizeCap`. Custom rails conform to
`Guardrail` (`id`, `stages`, `evaluate`) and register on the `PolicyEngine`.
Warnings are `GuardrailWarning` values delivered to any
`GuardrailActivitySink` (an `AIKitActivityStore` qualifies); delivery is awaited.
Use `resolvingContext:` when profile branches change. A nil `resolvedContext`
means unavailable context, distinct from an explicitly empty profile. Text rails
do not inspect image pixels: attachment-aware rails read `RenderedPrompt.prompt`.

Note: a `preToolUse` block surfaces from `respond` wrapped in the official
`LanguageModelSession.ToolCallError` — match `underlyingError`. A
`prePrompt` block surfaces raw.

## Errors, retries, deadlines

- Typed errors only: the official `LanguageModelError` taxonomy (429 →
  `.rateLimited`, timeouts → `.timeout`, blocks → `.guardrailViolation`),
  `ToolError`, `CancellationError`, `TurnRefusal`, `TurnDeadlineExceeded`,
  and provider shapes like `VolcengineArkError`.
- An explicitly enabled `AIKitTurnPolicy.retry` (`RetryPolicy`) re-sends
  transient failures on the same session. Model-authored garbage that
  fails a strict typed decode (`GeneratedContent.ParsingError`) is
  retriable — the fresh attempt lets the model re-emit correct arguments.
- Tools that want *in-session* self-correction should catch their own
  validation problems and return descriptive error strings; a thrown tool
  error aborts the attempt (official `ToolCallError`) and is handled by the
  turn-level retry policy.
- `AIKitTurnPolicy.deadline` is a cooperative budget covering execution and
  retry backoff (`TurnDeadlineExceeded` on overrun).

## Activity, external work, usage

- `AIKitActivityStore` aggregates busy state across conversations and
  host-run external work: `begin(_:onCancel:)` / `update` / `end`,
  `cancelAll()`, live `updates()` snapshots, and recent guardrail warnings
  (it conforms to `GuardrailActivitySink`). Cancel All invokes real cancellation
  handles and keeps items busy until their owners call `end`. Snapshot streams
  buffer only the newest state.
- Pass a `SwiftDataSessionUsageStore` as an `AIKitConversation`'s
  `usageRecorder` and every turn lands a durable `AIKitSessionUsageRecord`
  (model, provider, duration, round trips, per-turn token delta, outcome:
  completed / failed / cancelled / refused). Cached input and reasoning output
  token counts are retained; older persisted totals decode with zero defaults.
- To measure response rounds across retries and history compaction, create one
  `AIKitTurnMetrics` per session, apply `.measuringRounds(with: metrics)` **before**
  throwing response hooks such as `.guardrails`, and pass `metrics` to the
  conversation. Without the hook, counts cover retained response entries only.
  Cumulative token deltas still include rolled-back attempts. Static usage labels
  describe the aggregate; a profile that changes models needs a host billing
  ledger for per-model attribution.

## View contexts (per-screen prompt + tool scoping)

Each screen pushes a `ViewContext` — a system-prompt fragment, a tool-name
subset, and metadata — while it is visible. Resolve the stack into a
profile's instructions and tool subset when building the session for a
screen-scoped task; `ContextResolver.merged()` returns the combined
snapshot. In SwiftUI:

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

## UI

`AIKitConversationView(conversation:)` and
`AIKitChatbotOverlay(conversation:mode:)` are the primary surfaces. The same
conversation drives text and voice. Use `.aiChatbotOverlay(conversation:)` as a
view modifier, or the conversation initializer on `AIKitChatbotTabBar`.
The tab wrapper uses a public accessory Button; it never inspects UIKit's
private view hierarchy. Voice cancellation waits for old cleanup before restart.

Use `conversation.validatedTranscript` for UI/history export; raw preserved
failures stay available only through `session.transcript` for host recovery.
Initial history supplied to a new session must already be validated.

The presenter keeps validated transcript lines separate from the pending prompt
and the latest error. It buffers generated text and reasoning until hooks accept
the turn. Cancellation, activity, deadlines, retries, and usage all run through
the conversation. Keep one presenter per conversation UI owner; direct external
session calls do not automatically refresh an existing presenter's projection.

`AIKitView` edits descriptive, in-memory configuration. Changes apply atomically
to current fields and subscribers see tool/host edits. The host explicitly applies
preferences when constructing new sessions. Safety settings are host policy:
`SetAIKitConfigurationTool` denies model writes unless an `authorize` closure
allows that exact section/key. A typical grant permits a preference, never an
arbitrary safety override.

```swift
let tools = AIKitConfigurationTools.all(store: configurationStore) { section, key in
    section == .core && key == "model" // host-approved preference only
}
```

## Credentials and optional providers

Apple-only consumers import `AIKitCore`, `AIKitSafety`, `AIKitRuntime`, or
`AIKitUI`; those targets do not build the Ark implementation. The umbrella
continues to include `AIKitProviders` for compatibility. Direct users of the old
Core model selector now import `AIKitProviders`.

```swift
let credentials = try AIKitProviderCredentialStore.load()
// Keychain failures propagate. Present the error; do not log keys or silently
// substitute an empty credential when secure storage is unavailable.

var updated = credentials
updated.setAPIKey(newKey, for: .ark)
try updated.save()

// Tests/previews never need the real Keychain.
let memory = AIKitInMemoryCredentialStorage()
let preview = try AIKitProviderCredentialStore.load(storage: memory, migrating: nil)

// Optional cloud catalog transport, supplied explicitly to the dashboard.
import AIKitProviders
AIKitView(configurationStore: configurationStore, modelCatalog: AIKitModelCatalog())
```

Loading migrates legacy `AIKitProviderAPIKeys` preferences only after secure
persistence succeeds. Failure leaves legacy data available for a later retry.
Credentials use device-only Keychain accessibility and are never written back to
preferences. Credential APIs now throw; migrate existing `load()`/`save()` call
sites with `try` and host error presentation. The default dashboard catalog is
offline; inject the optional catalog to enable Ark model-list refresh.

## History and model changes

The host profile owns retention and model transitions. `historyTransform` limits
what is sent while leaving the session's canonical history intact. Preserve whole
prompt/tool/response groups when trimming; never leave orphaned tool outputs.
For durable compaction, change `session.transcript` inside `withTurn`, between
session operations, so it shares admission with generation.

A count of recent turns is a product retention rule, not a token guarantee.
When switching to a smaller system model, use its official `tokenCount(for:)`
and `contextSize` APIs, reserve space for tools/schema/output, and trim or
summarize before the transition. Custom providers need their own tokenizer or
budget contract. The deterministic history-transition test demonstrates profile
reevaluation without depending on a live model.

Conversation usage recording does not append an activity log to `MemoryStore`.
Hosts migrating `SearchMemoryTool` must deliberately write accepted turn entries
to their memory store inside `withTurn`, after successful validation, or choose
session transcript history as their retrieval source. This avoids silently
claiming legacy memory behavior on the new path.

## Testing

`AIKitTestSupport` ships `MockLanguageModel` — a scripted official
`LanguageModel` whose executor replays turns through the real generation
channel (text, reasoning, tool calls, usage), so tests exercise the same
native session loop as production, with no network. Tests use Swift
Testing; score agent behavior by side effects on your stores, never by the
model's prose.

## Multi-step agents

For select-then-work workflows (typed tool selection, host-stopped work
stage), use AIToolKit's `WorkflowProfile` family — reusable
`DynamicProfile`s driven directly through `LanguageModelSession(profile:)`.
Workflow stages ride official session properties declared with
`@SessionPropertyEntry`. Use `conversation.withTurn` when those turns need the
same activity, cancellation, and accounting policies as assistant UI.

## Migrating off `Orchestrator` (deprecated)

`Orchestrator` predates profiles owning the whole model pipeline; its
constructors and orchestrator-based UI initializers are deprecated; compatibility
facades remain until the next major release. The replacements:

| Legacy API | Replacement |
| --- | --- |
| `Orchestrator` | Direct `LanguageModelSession(profile:)`, or `AIKitConversation` for host policies |
| `OrchestratorModel` | `.model(...)` on the profile + `AIKitConversation.UsageLabels` |
| `Orchestrator.Options.temperature` / `.maxTokens` | `.temperature(...)` / `.maximumResponseTokens(...)` on the profile |
| `Orchestrator.Options.retry` / `.maxTurnDuration` | `AIKitTurnPolicy.retry` / `.deadline` |
| `Orchestrator.run(_:)` / `run(_:profile:)` | `session.respond` / `session.streamResponse` (or `conversation.respond`) |
| `OrchestratorEvent.llmDelta` | Validated `collectResponse`; native snapshots only for explicitly provisional UI |
| Tool call/result events | Profile lifecycle hooks and `Transcript.Entry` values |
| `.verification` warnings | `GuardrailActivitySink` / `AIKitActivityStore` warnings |
| `.failure(reason:)` | catch `TurnRefusal` (`.refusalEscapeHatch()`) |
| `OrchestratorActivity` / `beginExternalWork` | `AIKitActivityStore.Snapshot` / `begin(_:onCancel:)` |
| `OrchestratorSnapshot` | Compose `ContextResolver.merged()`, `session.transcript`, `session.usage`, and the activity store |
| UI `AIKitSession` | `AIKitConversationPresenter` over an `AIKitConversation` |
| `AIKitChatbotOverlay(orchestrator:)` / tab wrapper | Conversation initializer |
| Credential `load(defaults:)` / `save(defaults:)` | Throwing secure storage APIs with injected test storage |

The per-turn tool-guardrail semantics are unchanged: the same
`PolicyEngine` rails run at the same four observable boundaries, now
entirely inside the session machinery.
