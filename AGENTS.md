# AIKit — Working Notes

`README.md` is the usage guide; this file is operational guidance for
working on the package.

## Build & test

```sh
swift build
swift test
```

Swift 6, strict concurrency, language mode v6. No third-party dependencies.

## Module graph

`AIKitCore` → {`AIKitCapability`, `AIKitSafety`} → `AIKitRuntime` → `AIKitUI`.
Core, Runtime, Safety, and UI do not depend on a concrete cloud provider.
Optional `AIKitProviders` owns `AIKitLanguageModel`, Ark construction, model-list
transport, and Ark error classification. `AIKit` re-exports all products.
`AIKitTestSupport` contains scripted executors and in-memory persistence.
Sibling packages have their own operational guidance.

## Conventions

- Every public type is `Sendable`; shared mutable state lives in actors.
  No `@unchecked Sendable` anywhere. Non-`Sendable` SwiftData types stay
  actor-isolated inside the `@ModelActor` stores.
- Typed errors only: the official `LanguageModelError` (guardrail blocks
  throw `LanguageModelError.guardrailViolation` with railID/stage/reason in
  `metadata`), `ToolError`, provider shapes (`VolcengineArkError`),
  `AIKitModelCatalogError`, `AIKitModelResolutionError`. Never throw
  `NSError`/`String`.
- Logging via `OSLog`; subsystems are `com.aikit.<module>` (see `AIKitLog`).
- Tests use Swift Testing, never XCTest, never the network. HTTP-stub
  provider tests share a process-global stub — keep them in a
  `@Suite(.serialized)` suite.
- Prefer raw adoption of the official FoundationModels API over local
  bridges; AIToolKit's `FoundationModelsSupport` helpers are the canonical
  sugar layer (never duplicate them here).

## Architecture facts

- `AIKitConversation` owns one official session. Every governed operation uses
  `withTurn`: cancellation-aware FIFO admission, owned task cancellation,
  cooperative deadline including backoff, and shielded exactly-once settlement.
- Retries default to `.never`. Explicit retry asserts tools/host work are safe to
  repeat; transcript rollback cannot undo effects. Preserved history additionally
  requires `prepareForRetry`. Tool-hook errors are recursively unwrapped.
- `respond` returns the official conditional-Sendable response, including typed
  generation. `collectResponse` buffers native snapshots until hooks accept the
  turn; `onResponse` alone cannot prevent native provisional text disclosure.
- `.guardrails` runs all four stages on official hooks. A call-hook error is
  wrapped in `ToolCallError`; output-hook errors propagate raw. Argument decoding
  throws a wrapped `GeneratedContent.ParsingError`, not an automatic model retry.
- Apply `.refusalEscapeHatch()` before `.guardrails` so reportFailure can bail out
  even when an allowlist omits it. Apply `.measuringRounds` before throwing hooks
  and pass the same metrics instance to the conversation for rollback-safe counts.
- New overlay, tab and voice paths accept conversations. Orchestrator UI remains
  a deprecated compatibility facade until the next major release.
- Credentials use throwing, injected Keychain persistence. Tests use memory
  storage, never the user's real Keychain. Migration deletes preferences only
  after a successful secure write.
- Configuration is descriptive and in-memory. Use atomic store updates; the host
  applies preferences to profiles. Model writes require an explicit field grant.
- Cancel All keeps activity registered until execution and settlement finish.
  Deadlines cannot forcibly terminate tools that ignore cancellation.

## Traps

- **Region isolation:** passing a profile built with
  `.model(someAnyLanguageModel)` to `LanguageModelSession(profile:)` warns
  "sending 'profile' risks data races" — implicit existential opening
  mid-chain erases the opaque profile to `any DynamicProfile`. Fix: open
  the existential at a generic boundary (`model: some LanguageModel`) so
  the chain stays concrete. See the legacy `Orchestrator.turnSession`; open model existentials at a generic boundary.
- **Incremental builds hide warnings** from cached modules; `touch` the
  files (or all of `Sources`) before trusting a zero-warning grep.
- Never trust training data for the OS 27 FM protocol API
  (`DynamicProfile` hooks, executor channel, session properties); grep the
  SDK swiftinterface:
  `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
  Two non-obvious channel facts: there is no finish event (the finish
  reason rides entry metadata as `"finishReason"`), and executors/tests
  drain the channel with a final sentinel event after `respond` returns.

## Runtime verification

AIKit is a library with no example app; the host for runtime checks is the
Journal app (`~/Projects/Dev/Journal`), which links the local package.
