# AGENTS.md — Recommended practice for AI agents using AIKit

This is a reproduction guide. Following it, a capable agent can stand up the
**optimized two-round-trip workflow agent** that was validated on a deictic
personal-assistant domain and reach the same success and token numbers — without
re-deriving any of it. It is AIKit-centric (the **runner**); the planner/binder
prompt + schema contract lives in the sibling package **AIToolKit**
(`Sources/AIToolKit/WorkflowTwoRoundPrompt.swift` and
`Sources/AIToolKit/WorkflowTwoRoundSchema.swift`). Both are on GitHub; clone both.

> The one rule: **freeform planner + the built-in brace-balanced JSON extractor +
> auto-bind, at temperature 0.2.** That configuration is the proven best across
> model tiers. Everything below is detail and justification.

---

## 1. Pick the paradigm (decision rule)

All three run the same official `FoundationModels.Tool`s, handed over as
`[any Tool]` (AIToolKit's `ToolRegistry` is gone); they differ in how the plan
is produced.

```
1. Weak/small planner that can't reliably author a DAG?            → sequential loop
2. Task needs local/private/UI state referred to deictically
   ("the doc I have open", "the contact I'm viewing"), or
   disambiguation/refusal over local state?                        → TWO-ROUND-TRIP (this doc)
3. Capable planner, self-contained or named entities, ≥1 dependent → one-shot WorkflowSpec
4. Single tool call, no deps?                                      → any
```

A DAG paradigm wins from the first dependent step (sequential cost is ~quadratic
in depth; a DAG is ~flat). Reach for two-round when the model must **not see or
invent** private ids.

## 2. Stand up the two-round runner (copy this)

```swift
import AIKitRuntime   // WorkflowTwoRoundRunner
// AIToolKit provides WorkflowTwoRoundCompiler / Prompt / Schema / ContextHarvesting

let runner = WorkflowTwoRoundRunner(
    llm: client,                       // your LLMClient
    tools: tools,                      // the host's [any Tool] set (every tool)
    harvester: myHarvester,            // ContextHarvesting — deterministic, local, NO LLM
    plannerToolNames: plannerTools,    // the planner's tool universe (exclude context-reading tools)
    options: .init(
        model: modelID,
        sources: ["current_contact", "foreground_document", …],  // declarable harvest sources
        temperature: 0.2,              // NOT 0.0 (a malformed-JSON loop can't self-correct at 0.0)
        useStructuredPlannerOutput: false,   // freeform — see §5
        autoBind: true,                // default; collapses to ONE call when the harvest is unambiguous
        attemptsPerRound: 2            // one retry on a transient no-JSON
    )
)
switch await runner.run(intent: userText).outcome {
case .executed(let result): …          // the bound DAG ran
case .refused(let why):     …          // cannot_plan / cannot_bind / required-missing  (a SUCCESS, not an error)
case .failed(let why):      …          // malformed / validation / execution error
}
```

Pipeline: **Plan (isolated)** → local validate → deterministic **harvest** (no LLM)
→ **auto-bind** (skip round 2 when unambiguous) *or* **Bind (isolated)** → execute
the DAG. Round 1 never sees private ids; Round 2 never sees the full tool universe.

Thinking should be OFF (no reliability gain at these task sizes, large
token/latency cost). AIKit hardcodes the known deterministic provider toggles by
default: Ollama native chat sends top-level `"think": false`, and Volcengine Ark
chat-completions sends `"thinking": {"type": "disabled"}`. Use `extraBody` only
to override those defaults or to supply the equivalent key for another
OpenAI-compatible provider.

## 3. The planner output contract (lean — `two_round.planner.v2.1`)

The planner emits **only** `{"nodes":[…], "context_slots":[…]}`:

- a node is `{id, tool, input}`; `input` holds ONLY that tool's own params; wire a
  later node to an earlier one with `{"$ref":{"source":"node","node":"<id>","path":"/f"}}`;
- a context slot is `{slot_id, source}` — **no** `reason`, **no** `required`;
- **omit `intent_summary` and `outcome`** on the normal path (the runtime derives
  the outcome from structure); emit `"outcome":"cannot_plan"` (+ `message`) *only* to refuse;
- local deictic state → `{"$slot":"<id>"}` + a declared slot (never invent/fetch the id);
- to name harvested content in text → the `{{slot_id}}` token (the runtime substitutes the label).

This is ≈ **−44% planner output tokens** vs a verbose envelope, at equal-or-better
success. `WorkflowTwoRoundPrompt`/`WorkflowTwoRoundSchema` in AIToolKit produce it;
do not hand-roll a fatter shape.

### Guard rails (keep a STRONG planner robust on hard tasks)

A bare lean prompt *regressed* a strong model on hard tasks; these three clauses
recover it (cheap input, protects the output win):

1. a slot `source` must be **exactly** a declared source — never dotted/derived
   (`foreground_document.title` is invalid). *Also enforced in code* — see §4.
2. **never slot anything obtainable another way** — a *named* contact/document goes
   to a utility tool node; put its title in a subject literally or via the SAME
   deictic slot's `{{slot_id}}`, never a new title slot.
3. every interactive node keeps its required id fields **bound** (`$slot`/`$ref`/
   `$bind`/literal) — **never `null`**.

## 4. Robustness that is already built in — do NOT re-derive

- **String-aware, brace-balanced JSON extraction** (`WorkflowTwoRoundRunner.extract`
  `JSONObject` / `firstBalancedObject`). A weak planner on the `{{slot}}` path
  appends a stray `}` (the `{{ }}` token mis-counts its braces). The extractor
  ignores braces inside strings and stops at the first depth-0 close, so the valid
  object parses with **zero retries**. This — not structured output — is the
  weak-model robustness lever. Always on.
- **Source guard, code-enforced.** `WorkflowTwoRoundCompiler.validatePlan` takes
  `recognizedSources`; the runner passes `Set(options.sources)`, so an invented
  source fails fast (`unrecognizedSlotSource`) instead of silently as a harvest
  "missing". (Guard rail #1, promoted from prompt to guarantee.)
- **Binder is always freeform.** There is no binder-structured knob — a strict
  binder schema only tempts graph mutation and never measurably helped.
- **Validate / refuse, don't guess.** The runtime validates the plan, the binding
  preserves the graph, and resolved input is checked against each tool's schema.
  A clean `cannot_bind` / required-missing is a **success**.
- **A planned `reportFailure` node is a refusal.** If the planner phrases its
  bail-out as a node (`{"tool":"reportFailure","input":{"reason":…}}`) instead of
  `"outcome":"cannot_plan"`, the runner returns `.refused(reason)` before
  validation — it never executes as a no-op node, whether or not the planner
  manifest lists the tool. The sequential `Orchestrator` does the same for a
  direct call or a `workflow_run` node, and provides `reportFailure` by default
  (auto-registered, advertised with any non-empty tool subset) — hosts register
  nothing and never list it in `ViewContext.toolNames`.
- **`autoBind`** is correct-by-construction (one candidate ⇒ the Binder would pick
  it). Leave it on; ambiguity and text-authoring still fall through to the Binder.

## 5. Structured output — the decision (read this before reaching for it)

On the lean v2.1 schema, run the **planner freeform on every tier**. Do **not** set
`useStructuredPlannerOutput` here: the lean `input` is a free object, so under a
strict `response_format` a weak/mid model omits a required key (`missing required
property contactID`) or emits a duplicate node id — measured **lite 15/18** with
structured-planner vs **lite freeform 36/36 with the extractor**. Structured
*planner* output only pays off if the planner schema is first extended to mark each
interactive tool's required input keys required (it isn't, by default). The binder
is freeform unconditionally. (Structured output on the *one-shot* `WorkflowSpec`
path is a separate, fan-out-only consideration.)

## 6. Numbers to expect (so you can confirm a faithful reproduction)

Deictic context suite (`--auto-bind`, freeform, the recipe above), per task:

| | success | LLM calls | planner in / out tokens |
|---|---|---|---|
| strong model (e.g. doubao pro) | 36/36 | 1 (2 when binding) | ~970 / ~80 |
| mid model (e.g. doubao lite)   | 36/36 | 1 | ~970 / ~80 |

Hard complex-context ladder (7 tasks, full tool manifest): **aggregate 69/70**
(strong 34/35, mid 35/35) — *more* reliable than a verbose prompt and ~−26–28%
total tokens. The one residual miss is the L4 transform-chain attach (a known
ceiling). A weak/small model (e.g. mini) is off-label for two-round — prefer
sequential there.

## 7. Reproduce checklist & pitfalls

- [ ] Hand over all tools; give the planner the task's tools **minus** any
      context-reading tool (local state is a `$slot`, not a tool node).
- [ ] Use the AIToolKit lean prompt/schema as-is; keep the **two** worked examples
      and the three guard-rail clauses. Don't tailor the example per task.
- [ ] `temperature 0.2`, thinking off (handled by built-in provider defaults
      where the wire key is known), `autoBind: true`, `attemptsPerRound: 2`,
      **freeform** (no structured planner output).
- [ ] Implement `ContextHarvesting` deterministically: rank the current/foreground
      candidate first, cap the count, **report missing — never fabricate**.
- [ ] **Validate any prompt compaction on a HARD ladder with a LARGE tool
      manifest** — the strong-model regression from over-compaction is invisible on
      simple tasks. Don't drop the guard rails.
- [ ] Score by **side effects**, not the model's prose.

## Pointers
- This file is the single source of truth for the current two-round-trip
  reproduction recipe. AIKit `README.md` and AIToolKit `WORKFLOW_GUIDANCE.md` /
  `WORKFLOW_HOWTO.md` intentionally point back here instead of restating it.
- Runner implementation: AIKit `Sources/AIKitRuntime/WorkflowTwoRoundRunner.swift`.
- Prompt/schema/value-algebra implementation: AIToolKit
  `Sources/AIToolKit/WorkflowTwoRoundPrompt.swift`,
  `Sources/AIToolKit/WorkflowTwoRoundSchema.swift`, and
  `Sources/AIToolKit/WorkflowTwoRound.swift`.
