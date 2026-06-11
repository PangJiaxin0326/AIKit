# AGENTS.md — Recommended practice for AI agents using AIKit

This is the reproduction guide for the **scoped workflow (select-then-work)
agent**: one native `LanguageModelSession` over AIToolKit's
`ScopedWorkflowProfile`, two staged LLM calls — the model first *declares
the tool ids* the request needs against the user-visible catalogue, then
does *all the work* against only the selected tools and the assistive unit
requests registered on them. **Both steps are ended by the host, in code**
(throwing hooks), never by a model signal or a closing text turn. The
pieces live in the sibling package **AIToolKit** (`AssistiveTool.swift`,
`ScopedWorkflowProfile.swift` — including `WorkTurnMonitor`, the host-side
stop); the cloud model executor is `VolcengineArkFoundationModels` (nested
in this repo).

> Earlier paradigms were removed from this guide as they were superseded:
> the lean-plan DAG (library code survives at AIKit `81d3323` / AIToolKit
> `9fd1ea6`) and the gather→act profile workflow (recipe survives in this
> file's git history). Their measured numbers and root-cause analyses are
> recorded in the experiment repo (`Findings.md` Parts I–XVII).

## 1. The paradigm

```
ONE LanguageModelSession(profile: ScopedWorkflowProfile…)
  step .scope  →  instructions: select, don't act
                  tools: the FINISHING catalogue + select_tools
                  ends ON ARRIVAL of the select_tools call (throwing
                  onToolCall) — one LLM round, nothing executes
  host flips session.properties.scopedWorkflowStage = .work
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
  thing that crosses the stage boundary, and it crosses host-side
  (recorded in the `onToolCall` hook). A cut-index `historyTransform`
  drops every scope-step entry, so neither call carries the other's tool
  set or context — the context-budget property: the full catalogue is
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
    scopeInstructions: { scopeText },           // select, don't act
    workInstructions: { workText(localState) }, // the whole job + deictic state
    catalogue: finishing + [SelectToolsTool()],
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
.onToolCall { call in                            // fires BEFORE execution
    guard state.stage == .scope else { return monitor.recordCall(call) }
    if call.toolName == SelectToolsTool.toolName {
        state.selection = ScopedWorkflowProfile.parseSelection(
            (try? TextArgument(call.arguments))?.value ?? "",
            from: finishingNames)
        throw ScopeSelectionComplete()
    }
    throw ScopeStepViolation(toolName: call.toolName)  // blocks premature actions
}
.onToolOutput { call, _ in
    // The work step ends HERE, in code: turn fully executed + ≥1 action.
    if state.stage == .work, monitor.recordOutput(call) {
        throw WorkflowStageComplete()
    }
}
.transcriptErrorHandlingPolicy(.preserveTranscript)

let session = LanguageModelSession(profile: profile)
_ = try? await session.respond(to: "User request: \(userText)\n\nSelect the task tools this request needs.")
state.cutIndex = session.transcript.count
state.stage = .work
session.properties.scopedWorkflowStage = .work
_ = try await session.respond(to: "User request: \(userText)\n\nComplete this request now.")
```

For token accounting, install `VolcengineArkUsageMonitor.setHandler { … }` —
the FM session surface does not expose provider usage.

## 3. The host stop (why it is safe, and the traps)

`WorkTurnMonitor` counts the current tool turn from the hooks. Verified on
the OS 27 SDK: ALL of a parallel batch's `onToolCall`s fire **before the
first tool executes**, so the monitor knows the turn's size before any
output lands. Completion = `outputs == calls` AND ≥1 finishing output.
Therefore: a batched sibling action is never cancelled by the throw; a
pure-lookup turn never stops the session; a refusal (no finishing call)
ends on its normal text turn with no special case.

The traps — each one cost a battery:

1. **Keep entry 0 in the history transform.** The FM runtime does not
   append a second instructions entry on stage flip — it swaps the head
   entry in place before the transform runs. A naive `dropFirst(cut)` cuts
   the NEW instructions off and the work step runs with no system prompt
   at all (signature: deictic tasks fail, should-refuse tasks act).
2. **Unwrap sentinels from `.onToolCall`.** They reach the host wrapped in
   `LanguageModelSession.ToolCallError(tool:underlyingError:)` — match on
   `underlyingError`. (`.onToolOutput` throws propagate raw.)
3. **Validate like a real backend.** Small models batch an action WITH the
   lookup it depends on, binding `{{placeholders}}` or empty strings.
   Finishing tools must reject empty/unknown ids, garbage timestamps, and
   malformed tokens with a thrown error; a corrective respond (give the
   work step two) then fixes the run. Accepting an empty recipient
   silently is the dishonest behavior.
4. **Echo lineage in chain-shaped tools.** A tool whose output feeds its
   next call should echo its input (`next token: X (derived from 'Y')`) —
   bare opaque outputs make small models commit the wrong iteration.
5. **No model-side completion signal.** Don't add a `task_complete` tool:
   it reintroduces forgotten-signal rounds and fire-and-forget failures
   the host stop eliminates.
6. **Graceful fallbacks.** A text answer in the scope step is parsed for
   tool names (`parseSelection`, substring match); an empty selection
   scopes ALL finishing tools.

## 4. Prompt rails that are measured to matter

Scope step: "that selection is your ONLY job — do NOT perform the request,
do NOT call any task tool; call select_tools exactly once"; "select every
action the request requires; if unsure between two tools, include both;
lookups and missing details are handled in the next step" (refusal
decisions belong to the work step, which has the local state).

Work step: "batch ALL independent lookups into ONE turn as parallel tool
calls" (with `parallel_tool_calls` on the wire); "NEVER call an action tool
in the same turn as a lookup it depends on"; "issue ALL the action calls
together in ONE final turn once every id they need is in hand — the
session ends when that turn completes; an action issued in a later turn
will never run" (mandatory: this makes the host stop
complete-by-construction); "when the request specifies a NUMBER of
repeated calls, count your calls"; ALWAYS inject the local-state block
including explicit "none selected"/"AMBIGUOUS — do not guess" lines, with
the rail that deictic references "are ALREADY resolved in the local device
state above — do NOT try to look them up (the tools cannot see the user's
screen)" and the refusal rule (none/AMBIGUOUS → explain, perform NO
action).

## 5. Cost model (so the latency numbers don't surprise you)

Every call is structurally necessary: the scope call, one round per
dependent hop, the final action turn (stopped mid-flight by the host).
Deictic and refusal tasks = 2 calls; one-lookup actions = 3 (an action
cannot be issued before the lookup's result exists); a depth-N opaque
chain = N+2. Nothing below that is reachable in a session paradigm without
host-side dataflow execution — which is the retired DAG. Measured (20-task
light/medium battery, host-stop build): pro 20/20, step-1 mean 2.35 s,
total mean 8.48 s; mini 19/20 (95%), step-1 mean 1.19 s, total mean
4.70 s.

## 6. Reproduce checklist

- [ ] Finishing tools conform to `ScopedFinishingTool` and register their
      assistive tools; assistive misses return strings.
- [ ] Scope step: catalogue + `SelectToolsTool` only; throwing `onToolCall`
      records the selection and blocks any other call.
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
