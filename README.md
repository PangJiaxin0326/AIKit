# AIKit

A Swift package providing the foundation for AI-native apps. AIKit composes UI,
business logic, and profile/settings mutations through a unified agent pipeline
driven by an LLM.

Swift 6 · strict concurrency · iOS 26.5 / macOS 26.5 / visionOS 26.5 ·
MultiModalKit voice input.

## Modules

| Module            | Role                                                  |
|-------------------|-------------------------------------------------------|
| `AIKitCore`       | Model access via the Foundation Models protocol API   |
| `AIKitCapability` | Tools, view context, memory store                     |
| `AIKitRuntime`    | Session-driven orchestration, guardrail hooks, retries |
| `AIKitSafety`     | Verifier, guardrails, policy engine                   |
| `AIKitUI`         | SwiftUI helpers (`AIKitView`, `.aiContext`)           |
| `AIKit`           | Umbrella — re-exports everything                      |

Models ship as official `LanguageModel` conformances: Apple's
`SystemLanguageModel` and `PrivateCloudComputeLanguageModel` come from the
Foundation Models framework, and `VolcengineArkLanguageModel` from the
nested `VolcengineArkFoundationModels` package — providers are packages, as
Apple recommends. `AIKitCore` only selects and constructs a model value
(`AIKitLanguageModel`); every generation goes through an official
`LanguageModelSession` over it.

## Install

```swift
.package(url: "https://github.com/PangJiaxin0326/AIKit.git", branch: "main")
```

Add the `AIKit` product to your target.

## Quickstart

```swift
import AIKit

// 1. Model — remote models use host-owned API keys.
let model = AIKitLanguageModel.volcengineArk(
    apiKey: arkKey,
    model: "doubao-seed-2-0-lite-260215"
)
// Or use Apple's on-device model, when Apple Intelligence is available:
// let model = AIKitLanguageModel.appleIntelligence
// Or explicitly route through Private Cloud Compute on supported OS releases:
// let model = AIKitLanguageModel.privateCloudCompute

// 2. Tools available to the agent — the official [any Tool] currency.
let memory = try SwiftDataMemoryStore(path: dbPath)
let configurationStore = AIKitConfigurationStore()
var tools: [any Tool] = [
    NavigateTool { input in
        router.go(to: input.destination)
        return .init(navigated: true)
    },
    SearchMemoryTool(memory: memory),
]
tools += AIKitConfigurationTools.all(store: configurationStore)

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
    model: model,
    tools: tools,
    memory: memory,
    contextResolver: resolver,
    guardrails: policy
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

AIKit ships exactly three models, all behind the official Foundation Models
`LanguageModel` protocol:

- `.appleIntelligence` — `SystemLanguageModel.default`. On-device, no API
  key; requires Apple Intelligence to be available.
- `.privateCloudCompute` — `PrivateCloudComputeLanguageModel`. Apple's
  cloud endpoint with its own availability and quota surface.
- `.volcengineArk(apiKey:model:)` — `VolcengineArkLanguageModel` from the
  nested `VolcengineArkFoundationModels` package, which also exposes
  `VolcengineArkLanguageModelExecutor` for direct Foundation Models
  integration.

`AIKitLanguageModel.resolve(provider:modelID:credentials:)` builds the model
for a dashboard selection. The Core dashboard uses `AIKitProviderDefinition`
metadata (display names, key strategy, the static Apple Intelligence model
ids `apple-intelligence` / `private-cloud-compute`) and `AIKitModelCatalog`
for Ark's live model list. Because every model is an official
`LanguageModel`, tool calls, guided generation, streaming, and multimodal
prompts (image attachments) all use the system `LanguageModelSession`
implementations — AIKit adds no parallel transport. Hosts that want a raw
session can call `model.makeSession(tools:instructions:)` directly.

## SwiftUI

```swift
struct RootView: View {
    let orchestrator: Orchestrator
    let resolver: ContextResolver
    let configurationStore: AIKitConfigurationStore
    let tools: [any Tool]

    var body: some View {
        AIKitView(
            orchestrator: orchestrator,
            configurationStore: configurationStore,
            tools: tools
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
dashboard. `AIKitChatbotOverlay` can be applied to any view with
`.aiChatbotOverlay(orchestrator:)` when you want the assistant pet/dialog
entry point without the dashboard. The compact capsule supports voice input
through MultiModalKit's SpeechAnalyzer-backed transcription service.

## Architecture

The **Orchestrator** is the only stateful runtime component. Everything else is
a pure function or an actor owning a small slice of state. One `run(_:)` call is
one turn: the turn runs in one official `LanguageModelSession`, which executes
tools natively; the orchestrator wraps each tool so guardrails run at four
stages (`prePrompt`, `preToolUse`, `postToolUse`, `finalResult`) and events,
memory, usage records, retries, and the turn deadline stay host-visible.

For multi-step agents, the recommended paradigm is AIToolKit's
**profile-based workflow**: one native `LanguageModelSession` over
`WorkflowProfile`, staged by the `\.workflowStage` session property — a
gather stage seeing only `AssistiveTool` unit requests (scalar arguments,
tiny manifests), then an act stage seeing only the user-visible finishing
tools with local deictic state injected into its instructions. The DAG
workflow layer of earlier generations (`WorkflowSpec`, `workflow_run`,
planner/binder) was removed; it survives at `81d3323` and earlier.

The current reproduction recipe is intentionally not duplicated here. Treat
[AGENTS.md](AGENTS.md) as the single source of truth for the paradigm,
prompt rails, model settings, and the honest cost model.

## Testing

```sh
swift test
```

Tests use Swift Testing and never touch the network — the Ark executor takes an
injected `URLSession` (stubbed via `URLProtocolStub`) and the runtime uses
`MockLanguageModel`, a scripted official `LanguageModel` driven through a real
`LanguageModelSession`.
