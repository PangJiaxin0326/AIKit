# AIKit

A Swift package providing the foundation for AI-native apps. AIKit composes UI,
business logic, and profile/settings mutations through a unified agent pipeline
driven by an LLM.

Swift 6 · strict concurrency · iOS 17 / macOS 14 / visionOS 1 · no third-party
dependencies.

## Modules

| Module            | Role                                                  |
|-------------------|-------------------------------------------------------|
| `AIKitCore`       | Stateless LLM transport (Anthropic / OpenAI)          |
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

// 1. Provider — the host owns the API key.
let provider = AnthropicProvider(apiKey: myKey)
let llm = LLMClient(provider: provider)

// 2. Tools available to the agent.
let tools = ToolRegistry()
await tools.register(NavigateTool { input, _ in
    router.go(to: input.destination)
    return .init(navigated: true)
})
await tools.register(SearchMemoryTool())

// 3. View context — which prompt fragment and tools are live.
let resolver = ContextResolver()
await resolver.push(ViewContext(
    id: .init("home"),
    displayName: "Home",
    systemPromptFragment: "You help the user navigate the app.",
    toolNames: ["navigate", "searchMemory"]
))

// 4. Guardrails (all opt-in).
let policy = PolicyEngine(rails: [
    AllowlistedTools(allowed: ["navigate", "searchMemory"]),
    PIIRedactor(),
    InjectionSniffer(),
    OutputLengthCap(),
])

// 5. Orchestrate one turn.
let orchestrator = Orchestrator(
    llm: llm,
    tools: tools,
    memory: try SQLiteMemoryStore(path: dbPath),
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

## SwiftUI

```swift
struct RootView: View {
    let orchestrator: Orchestrator
    let resolver: ContextResolver

    var body: some View {
        AIKitView(orchestrator: orchestrator)
            .aiContextResolver(resolver)
            .aiContext(ViewContext(
                id: .init("root"),
                displayName: "Root",
                systemPromptFragment: "App-wide rules.",
                toolNames: ["navigate"]
            ))
    }
}
```

## Architecture

The **Orchestrator** is the only stateful runtime component. Everything else is
a pure function or an actor owning a small slice of state. One `run(_:)` call is
one turn: it may loop through several LLM↔tool iterations, with guardrails run
at four stages (`prePrompt`, `preToolUse`, `postToolUse`, `finalResult`). See
`GUIDE.md` for the full design.

## Testing

```sh
swift test
```

Tests use Swift Testing and never touch the network — providers take an injected
`URLSession` (stubbed via `URLProtocolStub`) and the runtime uses `MockProvider`.
