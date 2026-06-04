# AIKit

A Swift package providing the foundation for AI-native apps. AIKit composes UI,
business logic, and profile/settings mutations through a unified agent pipeline
driven by an LLM.

Swift 6 · strict concurrency · iOS 26.5 / macOS 26.5 / visionOS 26.5 ·
MultiModalKit voice input.

## Modules

| Module            | Role                                                  |
|-------------------|-------------------------------------------------------|
| `AIKitCore`       | Stateless LLM transport                               |
| `AIKitCapability` | Tools, view context, memory store                     |
| `AIKitRuntime`    | Orchestration loop, prompt builder, parser, retries   |
| `AIKitSafety`     | Verifier, guardrails, policy engine                   |
| `AIKitUI`         | SwiftUI helpers (`AIKitView`, `.aiContext`)           |
| `AIKit`           | Umbrella — re-exports everything                      |

## Install

```swift
.package(url: "https://example.com/AIKit.git", from: "1.0.0")
```

Add the `AIKit` product to your target.

## Quickstart

```swift
import AIKit

// 1. Provider — remote providers use host-owned API keys.
let provider = AnthropicProvider(apiKey: myKey)
// Or use Apple's on-device model, when Apple Intelligence is available:
// let provider = AppleIntelligenceProvider()
let llm = LLMClient(provider: provider)

// 2. Tools available to the agent.
let tools = ToolRegistry()
let configurationStore = AIKitConfigurationStore()
await tools.register(NavigateTool { input, _ in
    router.go(to: input.destination)
    return .init(navigated: true)
})
await tools.register(SearchMemoryTool())
await AIKitConfigurationTools.register(in: tools, store: configurationStore)

// 3. View context — which prompt fragment and tools are live.
let resolver = ContextResolver()
await resolver.push(ViewContext(
    id: .init("home"),
    displayName: "Home",
    systemPromptFragment: "You help the user navigate the app.",
    toolNames: ["navigate", "searchMemory", "getAIKitConfiguration", "setAIKitConfiguration"]
))

// 4. Guardrails (all opt-in).
let policy = PolicyEngine(rails: [
    AllowlistedTools(allowed: [
        "navigate",
        "searchMemory",
        "getAIKitConfiguration",
        "setAIKitConfiguration",
    ]),
    PIIRedactor(),
    InjectionSniffer(),
    OutputLengthCap(),
])

// 5. Orchestrate one turn.
let orchestrator = Orchestrator(
    llm: llm,
    tools: tools,
    memory: try SwiftDataMemoryStore(path: dbPath),
    contextResolver: resolver,
    guardrails: policy,
    options: .init(model: "claude-opus-4-7")
)

for try await event in await orchestrator.run("Take me to settings") {
    switch event {
    case .llmDelta(let text):       print(text, terminator: "")
    case .toolCall(let name, _):    print("\n[tool: \(name)]")
    case .finalAnswer(let answer):  print("\n\(answer)")
    case .error(let error):         print("\nerror: \(error)")
    default:                        break
    }
}
```

## Providers

AIKit ships providers for Anthropic, OpenAI, Ollama, and Apple Intelligence.
The Core dashboard uses shared `AIKitProviderDefinition` metadata for OpenAI,
Anthropic, Ollama, Apple Intelligence, and Volcengine Ark, including default
model-list URLs and streaming endpoints where providers expose them. Ollama's
streaming endpoint is editable; Apple Intelligence is presented as an
on-device option with a static local model.
`AppleIntelligenceProvider` uses Apple's on-device Foundation Models framework,
requires Apple Intelligence to be available on the device, and does not need an
API key. It reports `supportsNativeTools == false`, so AIKit enables the fenced
tool-call fallback and keeps dispatching tools through `ToolRegistry`.

Messages can include multimodal blocks:

```swift
let request = LLMRequest(
    model: "gpt-4o",
    messages: [
        Message(role: .user, content: [
            .text("Describe this and answer in voice."),
            .image(ImageContent(data: imageData, mimeType: "image/jpeg")),
            .audio(AudioContent(data: audioData, mimeType: "audio/wav", format: .wav)),
        ]),
    ],
    audioOutput: AudioOutputOptions(voice: "alloy", format: .mp3)
)
```

OpenAI supports image input, wav/mp3 audio input, and generated audio output.
Anthropic supports image input. Ollama supports base64 image input for
multimodal local models. Unsupported media modes throw `LLMError.unsupported`.

## SwiftUI

```swift
struct RootView: View {
    let orchestrator: Orchestrator
    let resolver: ContextResolver
    let configurationStore: AIKitConfigurationStore
    let tools: ToolRegistry

    var body: some View {
        AIKitView(
            orchestrator: orchestrator,
            configurationStore: configurationStore,
            toolRegistry: tools
        )
            .aiContextResolver(resolver)
            .aiContext(ViewContext(
                id: .init("root"),
                displayName: "Root",
                systemPromptFragment: "App-wide rules.",
                toolNames: ["navigate", "getAIKitConfiguration", "setAIKitConfiguration"]
            ))
    }
}
```

`AIKitView` renders the Core, Capability, Runtime, and Safety configuration
dashboard. `AIKitChatbotOverlay` (also available as `ChatbotOverlay`) can be
applied to any view with `.aiChatbotOverlay(orchestrator:)` when you want the
assistant pet/dialog entry point without the dashboard. The compact capsule
supports voice input through MultiModalKit's SpeechAnalyzer-backed
transcription service.

## Architecture

The **Orchestrator** is the only stateful runtime component. Everything else is
a pure function or an actor owning a small slice of state. One `run(_:)` call is
one turn: it may loop through several LLM↔tool iterations, with guardrails run
at four stages (`prePrompt`, `preToolUse`, `postToolUse`, `finalResult`). See
`GUIDE.md` for the full design.

For low-latency mobile agents, AIKit also supports AIToolKit `WorkflowSpec`:
the model can emit one topological JSON DAG containing multiple ordered or
dependent tool nodes, and the device executes those nodes locally without a
second LLM pass. In workflow-planning mode, providers see only the synthetic
`workflow_run` tool; app tools are supplied as catalog context. AIKit defaults
this path to AIToolKit's lean schema, fixed worked example, and temperature
0.2 guidance to reduce output tokens while keeping graph structure reliable.

For local/private context tasks, use `runWorkflowTask(...)` or
`WorkflowTwoRoundRunner`: the planner can declare context slots, AIKit harvests
trusted local candidates, auto-bind skips the binder when the result is
unambiguous, and `WorkflowPlanCache` can skip repeated planner calls.

### Two-round-trip runner recipe (v2.1)

`WorkflowTwoRoundRunner` is the orchestration half (the two isolated LLM calls +
the deterministic harvest + DAG execution); the lean planner/binder prompt
contract and the guard rails live in AIToolKit (`WorkflowTwoRoundPrompt` /
`WorkflowTwoRoundSchema`, documented in AIToolKit `WORKFLOW_GUIDANCE.md` §4b).
The current best-practice configuration — reproducible with no host context:

- **`autoBind: true` (default).** Collapses to **one** LLM call whenever the
  harvest is unambiguous (a sole/current candidate per referenced slot, nothing
  to author); ambiguity and label-authoring fall through to a second isolated
  Binder call. Round 1 never sees private ids; Round 2 never sees the full tool
  universe — the injection boundary and the cost win at once.
- **`temperature: 0.2`, thinking off.** At 0.0 a malformed-JSON loop can't
  self-correct.
- **Tier-matched structured output, planner only.** A *strong* planner runs
  freeform (≈0 malformed JSON); a *weak/mid* planner sets
  `useStructuredPlannerOutput: true` (the json_schema makes the nested-`$ref`
  malformed shape unrepresentable). Keep `useStructuredBinderOutput: false` — a
  strict schema tempts the binder to mutate the graph.
- **String-aware, brace-balanced JSON extraction (built in).** Weak planners on
  the `{{slot}}` authoring path append a stray `}` (the `{{ }}` token in a body
  string mis-counts their braces); `extractJSONObject` scans string-aware and
  stops at the first depth-0 close, so the otherwise-valid object parses with no
  retry. This — not structured output — is what makes the authoring path robust;
  it is always on, every tier.
- **The runtime validates, resolves, and executes — the model only proposes.** A
  clean `cannot_bind` / required-missing is a *success* (refusing beats guessing).

## Testing

```sh
swift test
```

Tests use Swift Testing and never touch the network — providers take an injected
`URLSession` (stubbed via `URLProtocolStub`) and the runtime uses `MockProvider`.
