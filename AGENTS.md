# AGENTS.md — Recommended practice for AI agents using AIKit

This is the reproduction guide for the **scoped workflow (select-then-work)
agent**: one native `LanguageModelSession` over AIToolKit's
`ScopedWorkflowProfile`, two staged LLM calls — the model first *declares
the tool ids* the request needs against the user-visible catalogue, then
does *all the work* against only the selected tools and the assistive unit
requests registered on them. The pieces live in the sibling package
**AIToolKit** (`AssistiveTool.swift`, `ScopedWorkflowProfile.swift`,
`WorkflowProfile.swift` for the shared `TaskCompleteTool`/
`WorkflowStageComplete` early-stop primitives); the cloud model executor is
`VolcengineArkFoundationModels` (nested in this repo).

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
                  assistive tools + task_complete
                  ends on the task_complete early stop — no closing text turn
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
import AIToolKit                       // ScopedWorkflowProfile, AssistiveTool
import VolcengineArkFoundationModels   // VolcengineArkLanguageModel

var extraBody = VolcengineArkConfiguration.defaultWireExtraBody
extraBody["parallel_tool_calls"] = .bool(true)
let model = VolcengineArkLanguageModel(configuration: .init(
    apiKey: key, model: modelID, defaultExtraBody: extraBody))

let profile = ScopedWorkflowProfile(
    scopeInstructions: { scopeText },           // select, don't act
    workInstructions: { workText(localState) }, // the whole job + deictic state
    catalogue: finishing + [SelectToolsTool()],
    workTools: { state.selected() + [TaskCompleteTool()] }
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
    guard state.stage == .scope else { return }
    if call.toolName == SelectToolsTool.toolName {
        state.selection = ScopedWorkflowProfile.parseSelection(
            (try? TextArgument(call.arguments))?.value ?? "",
            from: finishingNames)
        throw ScopeSelectionComplete()
    }
    throw ScopeStepViolation(toolName: call.toolName)  // blocks premature actions
}
.onToolOutput { call, _ in
    if call.toolName == TaskCompleteTool.toolName {
        guard state.finishingOutputs > 0 else { throw PrematureCompletion() }
        throw WorkflowStageComplete()
    }
    if finishingNames.contains(call.toolName) { state.finishingOutputs += 1 }
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

## 3. The traps (each one cost a battery)

1. **Keep entry 0 in the history transform.** The FM runtime does not
   append a second instructions entry on stage flip — it swaps the head
   entry in place before the transform runs. A naive `dropFirst(cut)` cuts
   the NEW instructions off and the work step runs with no system prompt
   at all (signature: deictic tasks fail, should-refuse tasks act).
2. **Unwrap sentinels from `.onToolCall`.** They reach the host wrapped in
   `LanguageModelSession.ToolCallError(tool:underlyingError:)` — match on
   `underlyingError`. (`.onToolOutput` throws propagate raw.)
3. **Guard the early stop.** Small models fire `task_complete` before doing
   any work, or batch it with the lookups. Only honor it after at least one
   FINISHING tool output; otherwise surface a recoverable error — a
   corrective respond sends the model back to work. Give the work step two
   corrective rounds.
4. **Validate like a real backend.** Small models batch an action WITH the
   lookup it depends on, binding `{{placeholders}}` or empty strings.
   Finishing tools must reject empty/unknown ids, garbage timestamps, and
   malformed tokens with a thrown error; the corrective respond then fixes
   the run. Accepting an empty recipient silently is the dishonest behavior.
5. **Echo lineage in chain-shaped tools.** A tool whose output feeds its
   next call should echo its input (`next token: X (derived from 'Y')`) —
   bare opaque outputs make small models commit the wrong iteration.
6. **Graceful fallbacks everywhere.** A text answer in the scope step is
   parsed for tool names (`parseSelection`, substring match); an empty
   selection scopes ALL finishing tools; a model that forgets
   task_complete pays the normal closing text turn. None of these are
   failures.

## 4. Prompt rails that are measured to matter

Scope step: "that selection is your ONLY job — do NOT perform the request,
do NOT call any task tool; call select_tools exactly once"; "select every
action the request requires; if unsure between two tools, include both;
lookups and missing details are handled in the next step" (refusal
decisions belong to the work step, which has the local state).

Work step: "batch ALL independent lookups into ONE turn as parallel tool
calls" (with `parallel_tool_calls` on the wire); "NEVER call an action tool
in the same turn as a lookup it depends on"; "when the request specifies a
NUMBER of repeated calls, count your calls"; "include task_complete IN THE
SAME turn as the final action call, listed last — do NOT wait to see the
action's result"; ALWAYS inject the local-state block including explicit
"none selected"/"AMBIGUOUS — do not guess" lines, with the rail that
deictic references "are ALREADY resolved in the local device state above —
do NOT try to look them up (the tools cannot see the user's screen)" and
the refusal rule (none/AMBIGUOUS → explain, perform NO action).

## 5. Cost model (so the latency numbers don't surprise you)

One model round per dependent hop is the irreducible cost: deictic tasks =
2 calls (scope + one work turn batching the action with task_complete);
single-lookup actions = 3 calls; a depth-N dependent chain = N+2±1. The
scope step is the paradigm's fixed cost — ~1,200 input tokens, 0.6–3 s —
and it buys manifest isolation, not extra rounds. Measured (20-task
light/medium battery): pro 20/20 with step-1 mean 2.56 s; mini 19/20 (95%)
with step-1 mean 1.23 s; step-1 stays under the 3 s budget on all tiers.

## 6. Reproduce checklist

- [ ] Finishing tools conform to `ScopedFinishingTool` and register their
      assistive tools; assistive misses return strings.
- [ ] Scope step: catalogue + `SelectToolsTool` only; throwing `onToolCall`
      records the selection and blocks any other call.
- [ ] Cut-index `historyTransform` that KEEPS entry 0.
- [ ] Early stop wired (task_complete + onToolOutput throw +
      preserveTranscript) and guarded by a finishing-output count.
- [ ] Finishing tools validate ids/timestamps/tokens like a real backend.
- [ ] User intent verbatim in both prompts; local state injected in work
      instructions unconditionally.
- [ ] `parallel_tool_calls` enabled; temperature 0.2; thinking off
      (provider default).
- [ ] Score by side effects on your domain store, never by the model's
      prose.
