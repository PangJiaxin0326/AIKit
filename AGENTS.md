# AGENTS.md — Recommended practice for AI agents using AIKit

This is the reproduction guide for the **scoped workflow (select-then-work)
agent**: one native `LanguageModelSession` over AIToolKit's
`ScopedWorkflowProfile`, two staged LLM calls — the model first *names the
finishing tools* the request needs (a plain-text reply against the rendered
catalogue, tool calling disallowed), then does *all the work* against only
the selected tools and the assistive unit requests registered on them.
**Both steps are ended by host configuration, in code** — no model
completion signal, no closing text turn after acting. The pieces live in
the sibling package **AIToolKit** (`AssistiveTool.swift`,
`ScopedWorkflowProfile.swift` — including `WorkTurnMonitor`, the host-side
stop); the cloud model executor is `VolcengineArkFoundationModels` (nested
in this repo), which maps `GenerationOptions.toolCallingMode` to the wire's
`tool_choice`.

> Earlier paradigms were removed from code and docs as they were
> superseded: the lean-plan DAG (library code survives at AIKit `81d3323`
> / AIToolKit `9fd1ea6`) and the gather→act profile workflow
> (`WorkflowProfile`, removed from AIToolKit; recipe and code survive in
> git history). The experiment repo's history holds the comparative
> batteries.

## 1. The paradigm

```
ONE LanguageModelSession(profile: ScopedWorkflowProfile…)
  step .scope  →  instructions: name the tools, nothing else — the
                  finishing-tool catalogue is RENDERED INTO the
                  instructions as text; tool calling is DISALLOWED
                  (tool_choice: none), so the model answers in plain text
                  with the bare tool-name list (~3 output tokens) and
                  cannot act prematurely by configuration.
                  One round, ends on its own short text turn.
  host parses the names (parseSelection), flips
                  session.properties.scopedWorkflowStage = .work,
                  and sets the historyTransform cut index
  step .work   →  instructions: the whole job + injected local deictic state
                  tools: SELECTED finishing tools + their registered
                  assistive tools
                  ends the moment a fully-executed turn contains a
                  finishing output (WorkTurnMonitor + throwing
                  onToolOutput) — no completion signal, no text turn
```

- **Finishing tools** (`ScopedFinishingTool`) are ordinary
  `@Generable`-argument tools — the semantically complete actions a user
  could tap. Each registers the assistive unit requests that can resolve
  its arguments (`registeredAssistiveTools`); the work step's assistive
  scope is the union over the *selected* finishing tools, never the task's
  ground truth.
- **Assistive tools** (`AssistiveTool`) take one plain-text string, one
  integer, or nothing (`TextArgument`/`IntegerArgument`/`EmptyArguments`)
  and return one compact fact string. Lookup misses return descriptive
  strings ("no contact matches 'x'"), never throw.
- **The user intent is sent in BOTH calls.** The selection is the only
  thing that crosses the stage boundary, and it crosses host-side. A
  cut-index `historyTransform` drops every scope-step entry, so neither
  call carries the other's tool set or context. The catalogue rendered as
  `name: description` text costs ~150 tokens for 4 tools where the JSON
  manifests with argument schemas cost ~900 — the full tool surface is
  never co-resident with lookups, facts, or local state.
- **Local/deictic state** is injected into the work-step instructions by
  the host; the scope step never sees it, and no LLM round reads it.

## 2. Stand up the session (copy this)

```swift
import AIToolKit                       // ScopedWorkflowProfile, WorkTurnMonitor
import VolcengineArkFoundationModels   // VolcengineArkLanguageModel

var extraBody = VolcengineArkConfiguration.defaultWireExtraBody
extraBody["parallel_tool_calls"] = .bool(true)
let model = VolcengineArkLanguageModel(configuration: .init(
    apiKey: key, model: modelID, defaultExtraBody: extraBody))

let monitor = WorkTurnMonitor(finishingToolNames: finishingNames)
let profile = ScopedWorkflowProfile(
    scopeInstructions: { scopeText },           // name the tools, nothing else
    workInstructions: { workText(localState) }, // the whole job + deictic state
    catalogue: finishing,                       // rendered into scope instructions
    workTools: { state.selected() }             // selected + their registered assistive
)
.model(model)
.temperature(0.2)
.historyTransform { entries in
    // The runtime SWAPS the head instructions entry in place with the
    // current stage's instructions — ALWAYS keep entry 0, cut 1..<cut.
    entries.enumerated().compactMap { i, e in
        if i == 0, case .instructions = e { return e }
        return i >= state.cutIndex ? e : nil
    }
}
.onToolCall { call in
    if state.stage == .work { monitor.recordCall(call) }
    // scope-step calls are impossible: tool_choice is "none" on the wire
}
.onToolOutput { call, _ in
    // The work step ends HERE, in code: turn fully executed + ≥1 action.
    if state.stage == .work, monitor.recordOutput(call) {
        throw WorkflowStageComplete()
    }
}
.transcriptErrorHandlingPolicy(.preserveTranscript)

let session = LanguageModelSession(profile: profile)
// call 1 — one short text turn; parse the names out of it
let text = try await session.respond(to: "User request: \(userText)\n\nSelect the task tools this request needs.").content
state.selection = ScopedWorkflowProfile.parseSelection(text, from: finishingNames)
state.cutIndex = session.transcript.count
state.stage = .work
session.properties.scopedWorkflowStage = .work
// call 2… — host-stopped by WorkTurnMonitor; give 2 corrective rounds
_ = try await session.respond(to: "User request: \(userText)\n\nComplete this request now.")
```

For token accounting, install `VolcengineArkUsageMonitor.setHandler { … }` —
the FM session surface does not expose provider usage.

## 3. Why the selection is text, and the host stop

**Text, not a tool call:** on an OpenAI-style wire, any tool call bills
~30+ output tokens — the function-call envelope costs ~20 invisible tokens
on top of the visible JSON (measured on Doubao; `tool_choice: required`
does not shrink it). The bare tool-name list as text is ~3 tokens, and
`toolCallingMode(.disallowed)` makes premature actions impossible by
configuration — no hook guard, no violation handling.
`maximumResponseTokens` (profile init parameter, default 64) is the ramble
backstop; a truncated reply still substring-parses.

**The host stop:** `WorkTurnMonitor` counts the current tool turn from the
hooks. Verified on the OS 27 SDK: ALL of a parallel batch's `onToolCall`s
fire **before the first tool executes**, so the monitor knows the turn's
size before any output lands. Completion = `outputs == calls` AND ≥1
finishing output. Therefore: a batched sibling action is never cancelled
by the throw; a pure-lookup turn never stops the session; a refusal (no
finishing call) ends on its normal text turn with no special case.

The traps — each one cost a battery:

1. **Keep entry 0 in the history transform.** The FM runtime does not
   append a second instructions entry on stage flip — it swaps the head
   entry in place before the transform runs. A naive `dropFirst(cut)` cuts
   the NEW instructions off and the work step runs with no system prompt
   at all (signature: deictic tasks fail, should-refuse tasks act).
2. **Disallowed tool calling strips the tools from the request.** With
   `toolCallingMode(.disallowed)` the runtime sends NO tool definitions —
   a catalogue registered as tools silently vanishes (symptom: the scope
   step's input tokens collapse and the model guesses names). Render the
   catalogue into the scope instructions; `ScopedWorkflowProfile` does
   this itself.
3. **Unwrap `LanguageModelSession.ToolCallError`.** An error thrown inside
   a tool's `call` (e.g. argument validation) reaches the host wrapped in
   `ToolCallError(tool:underlyingError:)` — match on `underlyingError`.
   (`.onToolOutput` throws — the host stop — propagate raw.)
4. **Validate like a real backend.** Small models batch an action WITH the
   lookup it depends on, binding `{{placeholders}}` or empty strings.
   Finishing tools must reject empty/unknown ids, garbage timestamps, and
   malformed tokens with a thrown error; a corrective respond (give the
   work step two) then fixes the run.
5. **Echo lineage in chain-shaped tools.** A tool whose output feeds its
   next call should echo its input (`next token: X (derived from 'Y')`) —
   bare opaque outputs make small models commit the wrong iteration.
6. **No model-side completion signal.** Don't add a `task_complete` tool:
   it reintroduces forgotten-signal rounds and fire-and-forget failures
   the host stop eliminates — and its call envelope alone costs 10× the
   text selection.

## 4. Prompt rails that are measured to matter

Scope step: "that selection is your ONLY job — the tools cannot be called
in this step and the request must not be performed; reply with ONLY the
needed task tool names, comma-separated, nothing else"; "select every
action the request requires; if unsure between two tools, include both;
lookups and missing details are handled in the next step" (refusal
decisions belong to the work step, which has the local state).

Work step: "batch ALL independent lookups into ONE turn as parallel tool
calls" (with `parallel_tool_calls` on the wire); "NEVER call an action tool
in the same turn as a lookup it depends on"; "issue ALL the action calls
together in ONE final turn once every id they need is in hand — the
session ends when that turn completes" (mandatory: it makes the host stop
complete-by-construction); "when the request specifies a NUMBER of
repeated calls, count your calls"; "never write prose in a turn that
contains tool calls"; ALWAYS inject the local-state block including
explicit "none selected"/"AMBIGUOUS — do not guess" lines, with the rail
that deictic references "are ALREADY resolved in the local device state
above — do NOT try to look them up (the tools cannot see the user's
screen)" and the refusal rule (none/AMBIGUOUS → explain, perform NO
action).

## 5. Cost model (so the numbers don't surprise you)

Every call is structurally necessary: the scope call (~330 input tokens,
~3 output), one round per dependent hop, the final action turn (~100
output tokens for a typical action; stopped mid-flight by the host).
Deictic and refusal tasks = 2 calls; one-lookup actions = 3 (an action
cannot be issued before the lookup's result exists); a depth-N opaque
chain = N+2. Nothing below that is reachable in a session paradigm without
host-side dataflow execution — which is the retired DAG. Measured (20-task
light/medium battery, single-method build): mini **20/20**, step-1 0.79 s
mean at 3 output tokens, total mean 4.03 s.

## 6. Reproduce checklist

- [ ] Finishing tools conform to `ScopedFinishingTool` and register their
      assistive tools; assistive misses return strings.
- [ ] Scope step: catalogue handed to the profile (it renders the text);
      NO tools callable; reply parsed with `parseSelection`; empty
      selection falls back to the full finishing set.
- [ ] Cut-index `historyTransform` that KEEPS entry 0.
- [ ] `WorkTurnMonitor` fed from both hooks; `WorkflowStageComplete` thrown
      from `onToolOutput` when it reports completion. NO task_complete tool.
- [ ] Finishing tools validate ids/timestamps/tokens like a real backend.
- [ ] User intent verbatim in both prompts; local state injected in work
      instructions unconditionally.
- [ ] `parallel_tool_calls` enabled; temperature 0.2; thinking off
      (provider default).
- [ ] Score by side effects on your domain store, never by the model's
      prose.
