# AGENTS.md — Recommended practice for AI agents using AIKit

This is a reproduction guide. Following it, a capable agent can stand up the
**optimized two-round-trip workflow agent** that was validated on a deictic
personal-assistant domain and reach the same success and token numbers — without
re-deriving any of it. It is AIKit-centric (the **built-in workflow tool pair**,
`WorkflowPlanTool` → `WorkflowExecuteTool`); the planner/binder prompt + schema
contract lives in the sibling package **AIToolKit**
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

## 2. Stand up the built-in tool pair (copy this)

The pipeline ships as two built-in `FoundationModels.Tool`s (the standalone
`WorkflowTwoRoundRunner` is gone): `workflow_plan` generates the DAG from the
tool manifest + intent and minimal context; `workflow_execute` consumes the
DAG + detailed/harvested context and runs it locally. Drive them host-side via
the typed APIs for a strict ≤2-LLM-call budget, or hand both to a session (the
outer context then carries two small built-ins instead of the whole manifest —
the 32K-class on-device/PCC posture).

```swift
import AIKitRuntime   // WorkflowPlanTool, WorkflowExecuteTool
// AIToolKit provides WorkflowTwoRoundCompiler / Prompt / Schema / ContextHarvesting

let sources = ["current_contact", "foreground_document", …]  // declarable harvest sources
let planTool = WorkflowPlanTool(
    llm: client,                       // your LLMClient
    tools: tools,                      // the host's [any Tool] set (every tool)
    plannerToolNames: plannerTools,    // the planner's tool universe (exclude context-reading tools)
    options: .init(
        model: modelID,
        temperature: 0.2,              // NOT 0.0 (a malformed-JSON loop can't self-correct at 0.0)
        useStructuredPlannerOutput: false,   // freeform — see §5
        attemptsPerRound: 2            // one retry on a transient no-JSON
    ),
    sources: sources
)
switch await planTool.plan(intent: userText).outcome {
case .refused(let why): …              // cannot_plan (a SUCCESS, not an error)
case .failed(let why):  …              // malformed / validation error
case .planned(let plan):
    let executeTool = WorkflowExecuteTool(
        llm: client,
        tools: tools,
        harvester: myHarvester,        // ContextHarvesting — deterministic, local, NO LLM
        sources: sources,
        options: .init(
            model: modelID,
            temperature: 0.2,
            autoBind: true,            // default; ZERO extra calls when the harvest is unambiguous
            attemptsPerRound: 2
        )
    )
    switch await executeTool.execute(plan: plan).outcome {
    case .executed(let result): …      // the bound DAG ran
    case .refused(let why):     …      // cannot_bind / required-missing  (a SUCCESS, not an error)
    case .failed(let why):      …      // malformed / validation / execution error
    }
}
```

Pipeline: **Plan (isolated call #1: manifest + intent, minimal context)** →
local validate → deterministic **harvest** (no LLM) → **auto-bind** (skip the
Binder when unambiguous) *or* **Bind (isolated call #2: the DAG + the candidate
packet, NO manifest)** → execute the DAG locally. Round 1 never sees private
ids; Round 2 never sees the full tool universe. Both tools also expose
`call(arguments:)` for session use: `workflow_plan` takes `{"intent": …}` and
returns the plan object, which is passed to `workflow_execute` unchanged.
Inside an `Orchestrator`, prefer `runWorkflowTask(...)`, which drives this
same pair as a tracked turn.

Thinking should be OFF (no reliability gain at these task sizes, large
token/latency cost). AIKit's Ark path sends
`"thinking": {"type": "disabled"}` by default. Use `extraBody` only to override
that default or to supply an equivalent key for another chat-completions
provider.

## 3. The planner output contract (lean — `two_round.planner.v2.3`)

The planner emits **only** `{"nodes":[…]}` plus `context_slots` when declaring
slots:

- a node is `{id, tool, input}` (short ids); `input` holds ONLY that tool's own
  params, with unused optionals **omitted** (never null filler); wire a later
  node to an earlier one with the compact `{"$ref":"<node id>/<field>"}` (the
  object form `{"$ref":{"node":…,"path":…}}` is still parsed; `source`
  defaults to `node`);
- a context slot is `{slot_id, source}` — **no** `reason`, **no** `required`;
- **omit `intent_summary` and `outcome`** on the normal path (the runtime derives
  the outcome from structure); emit `"outcome":"cannot_plan"` (+ `message`) *only* to refuse;
- local deictic state → `{"$slot":"<id>"}` + a declared slot (never invent/fetch the id);
- to name harvested content in text → the `{{slot_id}}` token (the runtime substitutes the label);
- **node-output text interpolation (v2.3, runtime-accepted but NOT taught)**:
  `{{<node id>/<path>}}` embeds an EARLIER node's output *inside* authored
  text (`"About {{d/hits/0/title}}"`); the executor substitutes it at run
  time and it creates a dependency edge like `$ref`. This closes the algebra
  gap that made strong models *invent* the form (measured: ~50% of pro plans
  on "mention the found document" tasks) — a `$ref` can only replace a whole
  field, never sit inside a sentence. **The prompt deliberately does not
  teach it**: adding it to the `{{ }}` clause made both tiers generalize the
  path form to *slots* (`{{open_doc/title}}`) and regressed the context suite
  from 48/48 to 32–36/48 — the prompt keeps the v2.2 "{{ }} wraps ONLY a
  declared slot_id" rule, and the runtime tolerates both drifts instead;
- **derived-parameter rail (v2.3)**: a parameter whose value is *derived* from
  an earlier node's output (computed size/count/date/formatted string) must be
  wired with `$ref` to the node that computes it, never replaced by a guessed
  constant;
- **completeness rail (v2.2)**: the plan executes ONCE — it must END with the
  action node(s) the request asks for; the planner never sees intermediate
  outputs, so list elements are picked by index using the tool's *documented
  ordering* (document your search tools' ordering — and any output field whose
  meaning could be mistaken for the requested value, e.g. a calendar slot's
  *capacity* vs the duration to book).

This is ≈ **−44% planner output tokens** vs a verbose envelope (v2.1), and the
v2.2 compact refs cut another ~15–30% on multi-edge plans — which is also the
*latency* lever, since decode dominates wall-clock.
`WorkflowTwoRoundPrompt`/`WorkflowTwoRoundSchema` in AIToolKit produce it; do
not hand-roll a fatter shape.

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

- **String-aware, opener-stack JSON extraction with repair**
  (`WorkflowJSONExtraction.extractJSONObject` / `firstBalancedObject`). Beyond
  ignoring braces inside strings and dropping a stray *trailing* brace, the
  scanner keeps a real `{`/`[` stack and repairs three provably-invalid byte
  patterns — each only fires where valid JSON is impossible, so well-formed
  output passes byte-identical: **mismatched closers** are dropped (the
  mid-plan miscount `…"input":{…}}},{"id":…`); a **stray quote after a closed
  value** is dropped (`…}}"}]}` — a `"` can never follow `}`/`]`); an
  **under-closed document** ending at a structural boundary is completed by
  closing the open stack (the missing-`}`-before-`]}` tail) — truncation
  *inside* a string is never completed (that would fabricate a value).
  Malformed output was a guaranteed parse failure, so repair-or-fail strictly
  dominates. This — not structured output — is the weak-model robustness
  lever. Always on.
- **Deterministic plan normalization** (`WorkflowTwoRoundCompiler.normalizePlan`,
  applied by both built-in tools and by `WorkflowTool` before validation; no-op
  on plans that already validate): mis-tagged `{"$slot":"<node>/<path>"}` →
  `{"$ref":…}` when the prefix is a plan node id (including `$ref`-prefixed
  and dotted spellings: `{"$slot":"$ref:d1/hits/0/id"}`); mis-spelled text
  tokens canonicalized (`{{$ref.d1.hits.0.title}}` / `{{d1.hits.0.title}}` →
  `{{d1/hits/0/title}}`); a slot text token carrying a path collapses to the
  slot's label token (`{{open_doc/title}}` → `{{open_doc}}` — a slot has
  exactly one textual rendering, the candidate's label); a declared source
  of the form `<recognized>/<suffix>` truncates to the recognized head
  (`foreground_document/title` → `foreground_document`); forward refs →
  stable topological re-order (the DAG was right, only emission order was
  wrong); a used-but-undeclared slot (a `$slot` id or a text-token head)
  whose id IS a recognized source name gets its only-possible declaration
  `{slot_id: X, source: X}`. Digit-leading node ids are accepted
  (`isValidNodeID`) — rejecting a whole run over a style rule is bad
  economics. Genuinely ambiguous output still refuses/fails loudly.
- **Source guard, code-enforced.** `WorkflowTwoRoundCompiler.validatePlan` takes
  `recognizedSources`; both built-in tools pass their `sources`, so an invented
  source fails fast (`unrecognizedSlotSource`) instead of silently as a harvest
  "missing". (Guard rail #1, promoted from prompt to guarantee.)
- **Binder is always freeform.** There is no binder-structured knob — a strict
  binder schema only tempts graph mutation and never measurably helped.
- **Validate / refuse, don't guess.** The runtime validates the plan, the binding
  preserves the graph, and resolved input is checked against each tool's schema.
  A clean `cannot_bind` / required-missing is a **success**.
- **A planned `reportFailure` node is a refusal.** If the planner phrases its
  bail-out as a node (`{"tool":"reportFailure","input":{"reason":…}}`) instead of
  `"outcome":"cannot_plan"`, the built-in tools return `.refused(reason)` before
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

v2.3 contract on the built-in tool pair, validated 2026-06 on a 117-run
battery per model (deictic context suite ×8, L1–L6 complexity ladder ×3,
chain-depth sweep ×3; auto-bind, freeform, `perTask` scope, temp 0.2,
thinking off):

| | battery success | context suite | mean secs/run (median) |
|---|---|---|---|
| strong (doubao pro)  | **117/117 (100%)** | 48/48 · 1 call · ~4.0 s | **4.8** (4.3) |
| mid (doubao lite)    | **115/117 (98.3%)** | 48/48 · 1 call · ~3.9 s | **4.5** (4.1) |
| weak (doubao mini)   | (off-label, see below) | — | volatile (server stalls) |

Context-suite plans run ~85 out tokens; multi-action / 4-node ladder plans
~110–180 (those decode-bound runs are the 5–7 s tail). The mid tier's
residual 2/117 are real L5–L6 capability limits (one unrepairable malformed
plan, one self-typo'd node ref) — and mini remains off-label for the DAG
paradigm; prefer sequential there.

## 7. Reproduce checklist & pitfalls

- [ ] Hand over all tools; give the planner the task's tools **minus** any
      context-reading tool (local state is a `$slot`, not a tool node).
- [ ] Use the AIToolKit lean prompt/schema as-is; keep the **single** worked example
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
- Built-in tool pair implementation: AIKit
  `Sources/AIKitRuntime/WorkflowBuiltinTools.swift` (`WorkflowPlanTool`,
  `WorkflowExecuteTool`, `WorkflowJSONExtraction`).
- Prompt/schema/value-algebra implementation: AIToolKit
  `Sources/AIToolKit/WorkflowTwoRoundPrompt.swift`,
  `Sources/AIToolKit/WorkflowTwoRoundSchema.swift`, and
  `Sources/AIToolKit/WorkflowTwoRound.swift`.
