# AGENTS.md — Recommended practice for AI agents using AIKit

This is a reproduction guide for the **profile-based workflow agent**: one
native `LanguageModelSession` over a staged `DynamicProfile`, with the tool
set split into LLM-visible-only *assistive* unit requests and user-visible
*finishing* actions. The pieces live in the sibling package **AIToolKit**
(`AssistiveTool.swift`, `WorkflowProfile.swift`); the cloud model executor is
`VolcengineArkFoundationModels` (nested in this repo). Both are on GitHub.

> The previous paradigm — the lean-plan DAG with planner/binder rounds
> (WorkflowSpec, validator, executor, `WorkflowTool`, the built-in
> plan/execute tool pair) — was **removed end to end** in the profile
> refactor. It survives at AIKit `81d3323` / AIToolKit `9fd1ea6`, and its
> validated numbers are recorded in the experiment repo
> (`Findings.md` Parts IX–XVI). The decision record with the OS 27 API
> verification is the experiment repo's `VIABILITY.md`.

## 1. The paradigm

```
ONE LanguageModelSession(profile: WorkflowProfile…)
  stage .gather  →  instructions: collect facts; tools: ASSISTIVE only
                    (scalar-argument unit requests; tiny manifest)
  host flips session.properties.workflowStage = .act
  stage .act     →  instructions: complete the request + injected local
                    deictic state; tools: FINISHING only (user-visible)
```

- **Assistive tools** (`AssistiveTool`) take one plain-text string, one
  integer, or nothing (`TextArgument` / `IntegerArgument` /
  `EmptyArguments`) and return one compact fact string. Any tier of model
  can emit the call directly — there is no structured plan to author and
  therefore nothing to repair. Their schemas cost a few tokens each, which
  is the context-budget lever on a 32K-class on-device/PCC window.
- **Finishing tools** are ordinary `@Generable`-argument tools — the
  semantically complete actions a user could tap. Only these are
  user-visible; filter with `tool.isAssistive`.
- **Local/deictic state** is *injected* into the act-stage instructions by
  the host (render it from your store) — no LLM round is spent reading it,
  and the gather stage never sees it.
- Return lookup misses as descriptive strings ("no contact matches 'x'"),
  never throw: a thrown tool error fails the session turn; a "no match"
  fact lets the model adjust.

## 2. Stand up the session (copy this)

```swift
import AIToolKit                       // AssistiveTool, WorkflowProfile
import VolcengineArkFoundationModels   // VolcengineArkLanguageModel

var extraBody = VolcengineArkConfiguration.defaultWireExtraBody
extraBody["parallel_tool_calls"] = .bool(true)   // batch independent lookups in one round
let model = VolcengineArkLanguageModel(configuration: .init(
    apiKey: key, model: modelID, defaultExtraBody: extraBody))

let profile = WorkflowProfile(
    gatherInstructions: { gatherText },          // collect facts; no actions
    actInstructions: { actText(localState) },    // inject deictic state here
    assistiveTools: tools.filter(\.isAssistive),
    finishingTools: tools.filter { !$0.isAssistive }
)
.model(model)
.temperature(0.2)

let session = LanguageModelSession(profile: profile)
let facts = try await session.respond(to: "User request: \(userText)\n\nGather the facts…")
session.properties.workflowStage = .act
let final = try await session.respond(to: "Now complete the user's request using the action tools.")
```

Skip the gather respond when no assistive tools are in scope. For token
accounting, install `VolcengineArkUsageMonitor.setHandler { … }` — the FM
session surface does not expose provider usage.

## 3. Prompt rails that are measured to matter

- Gather: "batch ALL independent lookups into ONE turn as parallel tool
  calls" (with `parallel_tool_calls` on the wire) — this took a 3-lookup
  task from 6 LLM calls to 4.
- Gather: "compute derived values with tools — never by your own
  arithmetic" (the bytes→kB lesson from the DAG era still applies).
- Act: "perform EVERY action the user asked for"; "never invent ids: every
  id must come from the gathered facts or the local device state below".
- Act: ALWAYS inject the local-state block, including explicit
  "none selected" / "AMBIGUOUS — do not guess" lines, plus "if the state
  the user refers to reads none/AMBIGUOUS, explain and perform NO action".
  Skipping the block when context is empty measurably causes acted-on-guess
  failures on missing-context tasks.

## 4. The early stop (the closing text turn is NOT mandatory)

The session loop only ends on a model text turn — but the HOST can end it on
a tool result. There is no `ToolCallingMode` for it (`allowed`/`required`/
`disallowed` only); the supported combination is:

- append `TaskCompleteTool()` (AIToolKit) to each stage's tool set, and rail
  the instructions: "call task_complete IN THE SAME turn as your final tool
  call(s), listed last";
- attach `.onToolOutput { call, output in record(call, output); if
  call.toolName == TaskCompleteTool.toolName { throw WorkflowStageComplete() } }`
  and `.transcriptErrorHandlingPolicy(.preserveTranscript)`;
- catch `WorkflowStageComplete` around `respond(...)` as success.

Two facts to respect: (1) the aborted turn's tool CALLS stay in the
preserved transcript but its OUTPUTS do not — record them in the
`onToolOutput` hook and inject the facts into the act-stage instructions
(the host is the data plane); (2) a model that forgets the signal just pays
the normal text turn — graceful fallback. Measured effect: deictic tasks
2→1 calls (~2–4 s — under a 5 s budget), multi-lookup 4→3, depth-5 chain
8→7; the gather stage usually keeps its verify round (the model reasonably
wants to see lookup results before declaring completion).

## 5. Cost model (so the latency numbers don't surprise you)

The session pays one model round per tool batch. With the early stop:
deictic/simple tasks = 1 call (~2–4 s); a multi-lookup task = 3 calls
(lookup batch + completion-signal round + action batch, ~9–12 s); a depth-N
dependent chain = N+2 — each dependent call must round-trip its
predecessor's output through the model; that is the irreducible cost. The
DAG paradigm this replaced did every shape in one call (~4–5 s, 100%/98.3%
at 117 runs) because the model declared the dataflow once and the device
executed it locally. The profile paradigm buys API-native simplicity,
scalar-argument robustness, and the manifest split; it spends round trips
on dependent steps. Measure before promising latency.

## 6. Reproduce checklist

- [ ] Tools split assistive/finishing; assistive misses return strings.
- [ ] `parallel_tool_calls` enabled; gather prompt demands one-turn batching.
- [ ] Local state injected in act instructions unconditionally.
- [ ] Early stop wired (task_complete + onToolOutput throw + preserveTranscript
      + host-side fact log for the gather outputs).
- [ ] temperature 0.2; thinking off (provider default).
- [ ] Score by side effects on your domain store, never by the model's prose.
