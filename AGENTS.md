# AIKit — Working Notes

`GUIDE.md` is the source of truth for design. This file is operational guidance.

## Build & test

```sh
swift build
swift test
```

Swift 6, strict concurrency, language mode v6. No third-party dependencies.

## Module dependency order

`AIKitCore` → `AIKitCapability` → `AIKitSafety` → `AIKitRuntime` → `AIKitUI`,
with `AIKit` re-exporting all. `AIKitTestSupport` (MockProvider,
URLProtocolStub) is a non-shipping target the test targets depend on.

## Conventions

- Every public type is `Sendable`; shared mutable state lives in actors.
- No `@unchecked Sendable` in public API.
- Typed errors only: `LLMError`, `ToolError`, `OutputParser.ParserError`,
  `GuardrailViolation`. Never throw `NSError`/`String`.
- Logging via `OSLog`; subsystems are `com.aikit.<module>` (see `AIKitLog`).
- Tests use Swift Testing (`import Testing`), never XCTest, never the network.
  HTTP-stub provider tests share a process-global stub, so keep them in a
  `@Suite(.serialized)` suite.
