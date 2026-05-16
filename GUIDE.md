# AIKit — Implementation Guide

> A Swift package providing the foundation for AI‑native apps. AIKit lets an app
> compose UI, run business logic, and mutate profile/settings through a unified
> agent pipeline driven by an LLM.

This document is the single source of truth for implementing AIKit. Claude Code
should follow it top‑to‑bottom: read **§1 Architecture**, then implement modules
in the **§7 Implementation Phases** order, validating each milestone with the
tests prescribed in **§8**.

---

## 1. Architecture Overview

AIKit is organized around the user's four‑part mental model. Each part is a
separate SwiftPM target so it can be developed, tested, and depended on in
isolation.

```
┌────────────────────────────────────────────────────────────────────┐
│  Application (host SwiftUI app)                                     │
└────────────────────────────────────────────────────────────────────┘
                              │ AIKit (umbrella)
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  Part 3 — Runtime                                                   │
│  ┌────────────┐  ┌──────────────┐  ┌────────────┐  ┌────────────┐  │
│  │ Orchestrate│→ │ PromptBuilder│→ │ LLM (Core) │→ │OutputParser│  │
│  │   Loop     │  │              │  │            │  │            │  │
│  └─────┬──────┘  └──────────────┘  └────────────┘  └─────┬──────┘  │
│        │                                                  │         │
│        │            ┌──────────────────────────┐          │         │
│        └──────────► │  ErrorHandler / Retry    │ ◄────────┘         │
│                     └──────────────────────────┘                     │
└────────────────────────────────────────────────────────────────────┘
       ▲                       ▲                          ▲
       │ reads                 │ verifies                 │ executes
       │                       │                          │
┌──────┴───────┐   ┌───────────┴──────────┐   ┌───────────┴──────────┐
│ Part 1       │   │ Part 4               │   │ Part 1               │
│ Context /    │   │ Verification &       │   │ Tools registry       │
│ Memory       │   │ Guardrails           │   │                      │
└──────────────┘   └──────────────────────┘   └──────────────────────┘

                        ┌──────────────────────┐
                        │ Part 2 — Stateless   │
                        │ LLM Core (provider   │
                        │ abstraction)         │
                        └──────────────────────┘
```

The **Orchestration Loop** is the only stateful runtime component. Everything
else is a pure function or an actor that owns a small slice of state (registry,
memory log, view context).

### Data‑flow per turn

```
user instruction
      │
      ▼
[ViewContext] ── system prompt + tool subset ──┐
                                               ▼
[Memory] ── recent usage log ─────► [PromptBuilder] ─► RenderedPrompt
                                                            │
[Guardrails: pre‑prompt verify] ◄──────────────────────────┘
                                                            │
                                                            ▼
                                                       [LLM.call]
                                                            │
                                                            ▼
                                                    [OutputParser]
                                                            │
                                          ┌─────────────────┴─────────────────┐
                                          ▼                                   ▼
                                  ToolCall(s)                            FinalAnswer
                                          │                                   │
                          [Guardrails: pre‑tool‑use verify]                   │
                                          │                                   │
                                          ▼                                   │
                                  [Tools.invoke] ──► result                   │
                                          │                                   │
                          [Guardrails: post‑tool‑use verify]                  │
                                          │                                   │
                                          └─────► loop back to PromptBuilder  │
                                                                              ▼
                                                         [Guardrails: final verify]
                                                                              │
                                                                              ▼
                                                                          delivered
```

---

## 2. Package Layout

```
AIKit/
├── Package.swift
├── GUIDE.md
├── CLAUDE.md
├── README.md
├── Sources/
│   ├── AIKit/                  ← umbrella module, re‑exports public surface
│   ├── AIKitCore/              ← Part 2: stateless LLM
│   │   ├── LLMClient.swift
│   │   ├── LLMProvider.swift
│   │   ├── Message.swift
│   │   └── Providers/
│   │       ├── AnthropicProvider.swift
│   │       └── OpenAIProvider.swift
│   ├── AIKitCapability/        ← Part 1: tools, context, memory
│   │   ├── Tools/
│   │   │   ├── Tool.swift
│   │   │   ├── ToolRegistry.swift
│   │   │   └── ToolSchema.swift
│   │   ├── Context/
│   │   │   ├── ViewContext.swift
│   │   │   └── ContextResolver.swift
│   │   ├── Configuration/
│   │   │   └── AIKitConfiguration.swift
│   │   └── Memory/
│   │       ├── MemoryStore.swift
│   │       └── UsageEvent.swift
│   ├── AIKitRuntime/           ← Part 3: orchestration
│   │   ├── Orchestrator.swift
│   │   ├── PromptBuilder.swift
│   │   ├── OutputParser.swift
│   │   ├── ErrorHandler.swift
│   │   └── RetryPolicy.swift
│   ├── AIKitSafety/            ← Part 4: verification & guardrails
│   │   ├── Verifier.swift
│   │   ├── Guardrail.swift
│   │   └── PolicyEngine.swift
│   └── AIKitUI/                ← optional SwiftUI helpers
│       ├── AIKitView.swift
│       └── ViewContextModifier.swift
└── Tests/
    ├── AIKitCoreTests/
    ├── AIKitCapabilityTests/
    ├── AIKitRuntimeTests/
    ├── AIKitSafetyTests/
    └── AIKitIntegrationTests/   ← end‑to‑end with a mock provider
```

### Package.swift requirements

- `swift-tools-version: 6.0`
- `swiftLanguageModes: [.v6]` and `SwiftSetting.enableUpcomingFeature("StrictConcurrency")`
- Platforms: `.iOS(.v17)`, `.macOS(.v14)`, `.visionOS(.v1)`
- Targets follow the layout above; each Sources/ target maps to a SwiftPM target,
  with `AIKit` depending on all sub‑targets and re‑exporting them.
- Tests use **Swift Testing** (`import Testing`), not XCTest.
- No third‑party dependencies in v1. Networking uses `URLSession`; JSON uses
  `Codable` + `JSONEncoder/Decoder`.

---

## 3. Part 1 — Capability

### 3.1 Tools

A **Tool** is a typed, declarative unit of work the LLM can invoke. The registry
is process‑wide but allows per‑view subsetting via `ViewContext`.

```swift
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }            // stable identifier, e.g. "navigate"
    static var description: String { get }     // shown to the LLM
    static var schema: ToolSchema { get }      // JSON schema for Input

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output
}

public struct ToolContext: Sendable {
    public let viewID: ViewContext.ID
    public let memory: MemoryStore
    public let logger: Logger
}

public actor ToolRegistry {
    public static let shared = ToolRegistry()

    public func register<T: Tool>(_ tool: T)
    public func unregister(name: String)

    /// Returns the schema bundle for the given subset (used by PromptBuilder).
    public func manifest(for names: Set<String>) -> [ToolDescriptor]

    /// Dispatches an invocation by name; decodes input from JSON, encodes output.
    public func invoke(name: String, jsonInput: Data, context: ToolContext) async throws -> Data
}
```

Requirements:

- Tools must be `Sendable`; closures captured inside `invoke` must respect
  Swift 6 concurrency rules.
- Tool errors conform to `ToolError` and carry `isRetriable: Bool` so the
  ErrorHandler can decide whether to loop back.
- Built‑in tools (provided by AIKit, opt‑in): `navigate`, `setProfile`,
  `setSetting`, `searchMemory`, `getAIKitConfiguration`, and
  `setAIKitConfiguration`. Each lives in
  `Sources/AIKitCapability/Tools/Builtin/`.

### 3.2 Context

Every view in the host app owns a `ViewContext`. It declares the system prompt
contribution and the subset of tools available while that view is focused.

```swift
public struct ViewContext: Sendable, Identifiable {
    public let id: ID
    public let displayName: String
    public let systemPromptFragment: String
    public let toolNames: Set<String>
    public let metadata: [String: String]

    public struct ID: Hashable, Sendable, RawRepresentable {
        public let rawValue: String
    }
}

public actor ContextResolver {
    public func push(_ context: ViewContext)
    public func pop(_ id: ViewContext.ID)
    public func current() -> [ViewContext]   // stack: deepest view last
    public func merged() -> ResolvedContext   // merge stack into one bundle
}
```

`ContextResolver` is an actor because views can push/pop from concurrent tasks.
The merged `ResolvedContext` is what `PromptBuilder` consumes.

For SwiftUI ergonomics, `AIKitUI` exposes:

```swift
public extension View {
    func aiContext(_ context: ViewContext) -> some View
}
```

which uses `.onAppear`/`.onDisappear` (or a `ViewModifier` with a custom
environment object) to push/pop on the resolver.

### 3.3 Memory

A rolling, persisted log of user→agent interactions. It is **append‑only** with
windowed reads; the only destructive operation is `delete(id:)`, which forgets
a single record. Storage backend is pluggable; default is a SwiftData‑backed
store in v1, with an in‑memory implementation for tests.

```swift
public struct UsageEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let viewID: ViewContext.ID
    public let kind: Kind
    public let payload: Data       // opaque JSON

    public enum Kind: String, Codable, Sendable {
        case userInstruction, toolInvoked, toolResult, llmResponse, error
    }
}

public protocol MemoryStore: Sendable {
    func append(_ event: UsageEvent) async throws
    func recent(limit: Int, view: ViewContext.ID?) async throws -> [UsageEvent]
    func search(query: String, limit: Int) async throws -> [UsageEvent]
    func delete(id: UUID) async throws
}
```

Memory is **not** a vector store in v1 — `search` is keyword/regex. The protocol
is shaped so a vector backend can replace it later without breaking callers.

---

## 4. Part 2 — Core (Stateless LLM)

A pure transport layer. No memory, no retries, no parsing. Just `Request → Response`.

```swift
public struct LLMRequest: Sendable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var tools: [ToolDescriptor]
    public var temperature: Double?
    public var maxTokens: Int?
}

public struct LLMResponse: Sendable {
    public var content: [ContentBlock]   // text + tool_use blocks
    public var stopReason: StopReason
    public var usage: TokenUsage
}

public protocol LLMProvider: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMResponseChunk, Error>
}

public struct LLMClient: Sendable {
    public init(provider: LLMProvider)
    public func complete(_ request: LLMRequest) async throws -> LLMResponse
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMResponseChunk, Error>
}
```

### Provider configuration

`LLMProvider` implementations are constructed by the host app and injected. The
package ships two:

- **AnthropicProvider** — Messages API, default model
  `claude-opus-4-7`. Supports tool use blocks natively.
- **OpenAIProvider** — Chat Completions API, default model
  `gpt-4o`. Maps tool use to function calling.

Credentials come from `LLMProvider.Configuration` (passed in init); the package
never reads environment variables itself. The host app decides where keys live.

### Streaming

`stream(_:)` returns chunks for both text deltas and tool‑call deltas. The
Orchestrator chooses streaming vs. one‑shot based on `OrchestratorOptions`.

---

## 5. Part 3 — Runtime

### 5.1 Orchestrator

The single entry point host apps call once per user instruction.

```swift
public actor Orchestrator {
    public init(
        llm: LLMClient,
        tools: ToolRegistry,
        memory: any MemoryStore,
        contextResolver: ContextResolver,
        guardrails: PolicyEngine,
        options: Options = .init()
    )

    public func run(_ instruction: String) -> AsyncThrowingStream<OrchestratorEvent, Error>

    public struct Options: Sendable {
        public var maxIterations: Int = 8
        public var stream: Bool = true
        public var retry: RetryPolicy = .default
    }
}

public enum OrchestratorEvent: Sendable {
    case promptBuilt(RenderedPrompt)
    case llmDelta(String)
    case toolCall(name: String, input: Data)
    case toolResult(name: String, output: Data)
    case verification(stage: Verifier.Stage, outcome: Verifier.Outcome)
    case finalAnswer(String)
    case error(any Error)
}
```

The loop body, in pseudocode:

```
events = []
loop iteration = 0..<options.maxIterations:
    context     = contextResolver.merged()
    prompt      = PromptBuilder.build(instruction, context, memory, transcript)
    guardrails.verify(.prePrompt, prompt)            // Part 4
    response    = await llm.complete(prompt)
    parsed      = OutputParser.parse(response)

    switch parsed:
        case .final(text):
            guardrails.verify(.finalResult, text)
            emit(.finalAnswer(text)); return
        case .toolCalls(calls):
            for call in calls:
                guardrails.verify(.preToolUse, call)
                result = try await tools.invoke(call)
                guardrails.verify(.postToolUse, result)
                transcript.append(call, result)
                memory.append(toolInvoked, toolResult)
    continue
emit(.error(IterationLimitExceeded))
```

The Orchestrator is an actor so concurrent `run` calls on the same instance
serialize cleanly. Hosts wanting parallelism instantiate multiple orchestrators.

### 5.2 PromptBuilder

Pure function. Given the resolved context, recent memory window, and the
running transcript, produces an `LLMRequest`.

```swift
public enum PromptBuilder {
    public static func build(
        instruction: String,
        context: ResolvedContext,
        memory: [UsageEvent],
        transcript: [TranscriptEntry],
        toolManifest: [ToolDescriptor]
    ) -> LLMRequest
}
```

Rules:

- System prompt = AIKit base preamble + concatenated `systemPromptFragment` from
  the context stack (root → leaf).
- Memory enters as a compact `<recent-actions>` block at the end of the system
  prompt, capped at `Options.memoryWindow` events.
- Transcript becomes the `messages` array, oldest first.
- `tools` is filtered to the view's `toolNames` only.

### 5.3 OutputParser

Converts an `LLMResponse` into app‑aware intents.

```swift
public enum ParsedOutput: Sendable {
    case final(String)
    case toolCalls([ToolCall])
    case mixed(text: String, toolCalls: [ToolCall])
}

public enum OutputParser {
    public static func parse(_ response: LLMResponse) throws -> ParsedOutput
}
```

Errors: `OutputParser.Error.malformedToolInput(name:, raw:)` carries the bad
JSON so the ErrorHandler can re‑prompt with a corrective message.

### 5.4 ErrorHandler & RetryPolicy

```swift
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int = 3
    public var backoff: Backoff = .exponential(base: 0.4, cap: 4.0)
    public var retriableCategories: Set<ErrorCategory> = [.transient, .toolRetriable]
}

public enum ErrorCategory: Sendable {
    case transient            // network blip, 5xx
    case toolRetriable        // tool said isRetriable = true
    case malformedOutput      // parser failure
    case guardrailViolation   // never retriable
    case fatal
}

public actor ErrorHandler {
    public func handle(_ error: any Error, attempt: Int, policy: RetryPolicy) async -> Decision
    public enum Decision: Sendable { case retry, fallback(prompt: String), abort(any Error) }
}
```

Behavior matrix:

| Category            | Decision                                            |
|---------------------|-----------------------------------------------------|
| transient           | `.retry` with backoff                               |
| toolRetriable       | `.retry`, increment attempt, re‑include tool error  |
| malformedOutput     | `.fallback` with a corrective system message        |
| guardrailViolation  | `.abort`                                            |
| fatal               | `.abort`                                            |

---

## 6. Part 4 — Safety & Scale

### 6.1 Verifier

`Verifier` runs at four well‑defined stages. Each stage gets a list of
`Guardrail` checks from the `PolicyEngine`.

```swift
public enum Verifier {
    public enum Stage: String, Sendable {
        case prePrompt, preToolUse, postToolUse, finalResult
    }
    public enum Outcome: Sendable {
        case pass
        case warn(reason: String)
        case block(reason: String)
    }
}

public protocol Guardrail: Sendable {
    var id: String { get }
    var stages: Set<Verifier.Stage> { get }
    func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome
}
```

`GuardrailPayload` is an enum carrying the stage‑specific data (rendered prompt,
tool call, tool result, final text).

### 6.2 PolicyEngine

```swift
public actor PolicyEngine {
    public init(rails: [any Guardrail] = [])
    public func register(_ rail: any Guardrail)
    public func verify(_ stage: Verifier.Stage, _ payload: GuardrailPayload) async throws
}
```

`verify` collects all outcomes; **any `.block`** throws `GuardrailViolation`,
which the ErrorHandler will categorize as `.guardrailViolation` and abort.

### 6.3 Built‑in guardrails

Ship these in `Sources/AIKitSafety/Builtin/`:

- **PIIRedactor** (`preToolUse`) — refuses tool calls whose JSON input contains
  obvious PII patterns when the tool isn't tagged `acceptsPII`.
- **AllowlistedTools** (`preToolUse`) — blocks any tool not in the resolved
  context's `toolNames`. Defense in depth against prompt injection.
- **OutputLengthCap** (`finalResult`) — blocks responses over a configured
  character cap.
- **InjectionSniffer** (`prePrompt`) — flags user instructions containing common
  jailbreak phrases; emits `.warn` (not block) by default.

The host app can disable any of these by not including them in the
`PolicyEngine` it constructs.

---

## 7. Implementation Phases

Implement strictly in this order. Each phase ends with a green test target.

### Phase 0 — Skeleton (½ day)
1. Create `Package.swift` per §2.
2. Create empty source files for every type listed above so the package compiles.
3. Add `AIKit` umbrella target that re‑exports each sub‑target via `@_exported`.

**Exit:** `swift build` succeeds; `swift test` runs (empty suites).

### Phase 1 — Core (1 day)
1. Implement `Message`, `LLMRequest`, `LLMResponse`, `ContentBlock`,
   `TokenUsage`, `StopReason`.
2. Implement `LLMProvider` protocol + `LLMClient` wrapper.
3. Implement `AnthropicProvider` against the Messages API. Streaming via
   `URLSession.bytes(for:)`.
4. Implement `OpenAIProvider` against Chat Completions.
5. Add a `MockProvider` in tests that returns scripted responses.

**Exit:** Round‑trip a hello‑world request against `MockProvider` with both
streaming and non‑streaming codepaths.

### Phase 2 — Capability (1 day)
1. `Tool` protocol + `ToolRegistry` actor + JSON dispatch.
2. `ViewContext` + `ContextResolver` actor.
3. `MemoryStore` protocol + `InMemoryMemoryStore` + `SwiftDataMemoryStore`
   (use SwiftData via `import SwiftData`, no third‑party deps).
4. Built‑in tools: `navigate`, `setProfile`, `setSetting`, `searchMemory`,
   `getAIKitConfiguration`, `setAIKitConfiguration`.

**Exit:** Register a fake tool, invoke it through `ToolRegistry.invoke(name:…)`,
confirm event lands in memory.

### Phase 3 — Runtime (2 days)
1. `PromptBuilder.build(...)` — start with the deterministic structure in §5.2.
2. `OutputParser.parse(...)` — handle Anthropic tool_use blocks and OpenAI
   tool_calls.
3. `RetryPolicy` + `ErrorHandler` actor.
4. `Orchestrator` actor — implement the loop in §5.1 with full event streaming.

**Exit:** End‑to‑end test: instruction → mock LLM emits a tool call → tool
executes → mock LLM emits final answer → orchestrator yields `.finalAnswer`.

### Phase 4 — Safety (1 day)
1. `Verifier`, `Guardrail`, `PolicyEngine`.
2. Built‑in guardrails listed in §6.3.
3. Wire `PolicyEngine` into the Orchestrator at the four stages.

**Exit:** Tests prove that a blocked tool call short‑circuits the loop with
`GuardrailViolation` and never reaches the tool.

### Phase 5 — UI helpers & polish (½ day)
1. `AIKitUI.AIKitView` — a SwiftUI view that renders the Core, Capability,
   Runtime, and Safety configuration dashboard and can host the chatbot overlay
   when initialized with an `Orchestrator`.
2. `AIKitUI.AIKitChatbotOverlay` / `ChatbotOverlay` — a pet-style floating
   assistant entry point that shows current context, available tools, recent
   activity, and a prompt field.
3. `.aiContext(_:)` view modifier.
4. README quickstart.

---

## 8. Testing Strategy

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- One test target per source target plus an `AIKitIntegrationTests` target that
  exercises the full loop with `MockProvider`.
- **No network in tests.** `AnthropicProvider` / `OpenAIProvider` get their
  `URLSession` injected; tests use a `URLProtocol` stub.
- Use the **MockProvider** from §7 Phase 1 for all runtime + safety tests.
- Property‑style tests for `OutputParser` (round‑trip random tool calls through
  encode → parse).
- Concurrency tests: spin up 50 concurrent `Orchestrator.run` calls on
  independent instances; assert no data races (run with TSan in CI).

Coverage targets (advisory, not gates): Core 90%, Capability 85%, Runtime 80%,
Safety 90%.

---

## 9. Conventions & Constraints

- **Swift 6, strict concurrency.** Every public type is `Sendable` or has a
  documented reason it isn't. Mutable shared state lives in actors.
- **No `@unchecked Sendable`** in public API. Internal escape hatches must
  carry a `// swiftlint:disable:next` style justification comment.
- **No third‑party dependencies in v1.** Vector stores, telemetry, and richer
  parsing belong in companion packages.
- **Logging** goes through `import OSLog`. Each module owns a `Logger` with
  subsystem `com.aikit.<module>`.
- **Errors** are typed per module: `LLMError`, `ToolError`, `ParserError`,
  `GuardrailViolation`. Never throw `NSError` or `String` errors.
- **Public API stability:** until v1.0, mark experimental APIs with
  `@_spi(Experimental)`.

---

## 10. Glossary

- **View Context** — the per‑screen bundle of system prompt fragment + tool
  subset. Pushed when a view appears, popped on disappear.
- **Resolved Context** — the flattened result of merging the context stack.
- **Transcript** — the running list of `(LLM message, tool call, tool result)`
  triples for the current turn's iterations. Discarded after the turn ends; the
  durable record is in `MemoryStore`.
- **Turn** — one user instruction → one final answer. May contain N iterations
  of LLM↔tool ping‑pong.
- **Iteration** — one LLM call inside a turn.

---

## 11. Out of Scope (v1)

- Vector / embedding memory backends.
- Multi‑agent coordination (agent‑to‑agent messaging).
- Fine‑tuning hooks.
- Speech I/O.
- Persisted orchestrator state across app launches (each turn is fresh).

These are tracked for v2 and intentionally excluded here to keep v1 small and
correct.
