# AI Agent DAG Workflow Schema Design for One-Shot Edge Tool Execution

**Audience:** coding agent / Swift infrastructure implementer  
**Target repository area:** current four-file tool infrastructure: `Tool.swift`, `ToolSchema.swift`, `ToolRegistry.swift`, `ToolDescriptor.swift`  
**Primary goal:** replace repeated model-tool-model loops such as `Tool1() → Tool2() → Tool3()` with a single model request that emits a validated, executable DAG: `Workflow(Tool1(), Tool2(), Tool3(resultOfTool1, resultOfTool2), ...)`.

---

## 0. Executive recommendation

Implement **WorkflowSpec v1: an explicit JSON DAG intermediate representation (IR)**.

The model should not directly call `Tool1`, `Tool2`, `Tool3` as separate provider tool calls. Instead, the model should return exactly one workflow object, preferably as either:

1. a provider-enforced structured output matching `WorkflowSpec`, or
2. one synthetic tool call such as `workflow_run(spec: WorkflowSpec)`.

The edge runtime then validates and executes the graph locally without any further LLM call.

The existing `Tool` protocol and `ToolRegistry` should remain the foundation. Add a workflow layer around them:

```text
LLM request
  └── returns WorkflowSpec JSON
        └── WorkflowValidator checks schema, tool names, references, cycles, policy
              └── WorkflowExecutor runs topological levels concurrently
                    └── existing ToolRegistry dispatches individual tools
                          └── WorkflowResult is returned/rendered locally
```

The recommended schema is deliberately **not general code**. It is a constrained dataflow IR: tool nodes, references, local deterministic transforms, optional guards, and optional bounded fan-out. This gives most of the orchestration benefit of “agent writes a program once,” while avoiding the security and sandboxing burden of executing arbitrary model-generated code on edge devices.

---

## 1. Evidence and design principles from current frontier guidance

The design follows several patterns used by current agent systems:

1. **Prefer simple, inspectable orchestration before heavy frameworks.** Anthropic’s “Building Effective Agents” recommends starting from direct LLM APIs and understanding the underlying code rather than assuming a framework will hide orchestration complexity. The DAG executor should therefore be a small, explicit runtime rather than a black-box agent loop.  
   Source: https://www.anthropic.com/engineering/building-effective-agents

2. **Treat tool definitions as model-facing API documentation.** Anthropic’s tool-use docs emphasize a name, detailed description, JSON Schema input schema, and optional examples. Their guidance says detailed descriptions are the most important factor in tool performance. The workflow prompt should include a compact tool catalog with strong descriptions and examples.  
   Source: https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools

3. **Exploit parallelism only when dependencies are absent.** Anthropic’s prompting guidance notes that modern models are good at parallel tool execution and should run independent operations in parallel, while dependent calls must not use placeholders or guessed parameters. This maps directly to a DAG where independent nodes become the same execution level.  
   Source: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices

4. **Reduce context, latency, and result-copying by moving orchestration out of the LLM loop.** Anthropic’s code-execution-with-MCP discussion identifies two bottlenecks in direct tool loops: large tool definitions and intermediate results accumulating in context. A one-shot workflow has the same motivation: intermediate outputs stay in the edge runtime unless explicitly returned.  
   Source: https://www.anthropic.com/engineering/code-execution-with-mcp

5. **Use strict structured output wherever available.** OpenAI’s function-calling guidance recommends strict mode, where schemas require `additionalProperties: false` and all fields are required, with nullable types used for optional values. The workflow schema should be canonicalized into the provider’s strict subset when used as a model response format or synthetic tool input.  
   Source: https://developers.openai.com/api/docs/guides/function-calling

6. **Preserve user visibility and permission boundaries.** MCP’s tool specification frames tools as model-controlled but recommends clear UI indicators and human approval for operations where needed. A workflow may contain multiple tool invocations, so approval and side-effect policy must be checked at graph-validation time, not only per node after execution starts.  
   Source: https://modelcontextprotocol.io/specification/2025-06-18/server/tools

---

## 2. Current Swift infrastructure summary

The uploaded files define a clean minimal tool layer:

### `Tool.swift`

Current concepts:

- `Tool` protocol with associated `Input` and `Output`, both `Codable & Sendable`.
- Static metadata: `name`, `description`, `inputSchema`.
- Runtime call: `call(_ input: Input, in context: ToolContext) async throws -> Output`.
- `ToolContext` with `viewID`, metadata, logger.
- `ToolError` with `isRetriable`.
- `ToolCall` with optional `id`, `name`, and `input: JSONValue`.
- `ToolRegistryError` for dispatch decoding/encoding errors.

### `ToolSchema.swift`

Current concepts:

- Small JSON Schema builder.
- Supports primitive schemas, arrays, and objects with `properties` and `required`.

### `ToolRegistry.swift`

Current concepts:

- Actor-based process-wide registry.
- Registers typed tools by erasing them into `Entry` objects.
- Produces descriptors and manifests.
- Dispatches by name, decoding input JSON data into `T.Input` and encoding output into data.

### `ToolDescriptor.swift`

Current concepts:

- Provider-agnostic `name`, `description`, and `inputSchema`.
- `Identifiable` by name.

### Gap for DAG workflows

The current system can execute a single tool call but lacks:

- output schemas;
- tool side-effect metadata;
- graph schema;
- dependency references between tool outputs and later inputs;
- graph validation;
- concurrency scheduling;
- deterministic error policy;
- workflow-level return rendering;
- telemetry for multi-node execution.

The workflow design should add those without weakening the typed `Tool` abstraction.

---

## 3. Core requirements

### Functional requirements

1. The LLM must return one complete workflow in one request.
2. The workflow must represent a DAG of tool calls.
3. A node may depend on one or more predecessor nodes.
4. A node input may contain literal values and references to prior outputs.
5. Independent nodes should run concurrently.
6. The edge runtime must validate the graph before running it.
7. The edge runtime must execute the graph without further LLM calls.
8. The runtime must expose a final result deterministically.
9. The runtime must be provider-agnostic: usable with OpenAI structured outputs, Anthropic tool use, or any other model that can emit JSON.
10. Existing tools should continue to work after minimal metadata additions.

### Non-functional requirements

1. No arbitrary model-generated code in the recommended v1 path.
2. No hidden unbounded loops.
3. No implicit network or destructive action unless the underlying tool is approved by policy.
4. All intermediate outputs should be size-capped and redaction-aware.
5. All node execution should be observable and replayable in tests.
6. Schema validation failures should be local and deterministic.
7. Provider-specific strict-schema quirks should be isolated in an adapter layer.

### Important one-shot limitation

A one-shot workflow cannot ask the model to interpret unseen tool outputs after execution. Therefore, the final answer must be one of:

1. the raw or projected output of a final tool node;
2. a deterministic JSON object assembled from node outputs;
3. a deterministic string template with placeholders resolved from node outputs;
4. the output of a local non-LLM formatting/summarization tool;
5. a workflow failure/clarification response prepared by the model before execution.

Do not design the executor to silently make a second LLM call for final synthesis. That would violate the one-request objective.

---

## 4. Recommended architecture

```text
┌─────────────────────────────────────────────────────────┐
│ PromptBuilder                                           │
│ - system instructions                                   │
│ - compact tool catalog                                  │
│ - WorkflowSpec JSON Schema                              │
└─────────────────────────────────────────────────────────┘
                 │ one model request
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Model response                                           │
│ - WorkflowSpec                                           │
│ - or unsupported/needs_clarification object              │
└─────────────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│ WorkflowDecoder                                          │
│ - parse JSON                                             │
│ - provider adapter normalization                         │
└─────────────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│ WorkflowValidator                                        │
│ - schema validity                                        │
│ - tool existence and allowlist                           │
│ - no cycles / topological order                          │
│ - reference validity                                     │
│ - permission and side-effect policy                      │
│ - resource limits                                        │
└─────────────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│ WorkflowExecutor                                         │
│ - levelize DAG                                           │
│ - resolve references                                     │
│ - validate node input                                    │
│ - call ToolRegistry                                      │
│ - validate and store output                              │
│ - apply retry/error policy                               │
└─────────────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│ WorkflowResult                                           │
│ - final value or template-rendered answer                │
│ - trace                                                  │
│ - per-node status                                        │
│ - redacted diagnostics                                   │
└─────────────────────────────────────────────────────────┘
```

---

## 5. WorkflowSpec v1: explicit DAG JSON IR

### 5.1 Design philosophy

The recommended schema is a graph IR, not a programming language.

- The model declares **what** to call and **how data flows**.
- The runtime decides **when** each node can run based on dependencies.
- The runtime never guesses missing parameters.
- The runtime never interprets arbitrary expressions.
- Dynamic behavior is limited to safe built-in node kinds, added gradually.

### 5.2 Top-level object

Example top-level shape:

```json
{
  "schema_version": "workflow.v1",
  "workflow_id": "wf_weather_and_calendar_001",
  "intent": "Check tomorrow's weather and create a reminder if rain is likely.",
  "mode": "execute",
  "nodes": [],
  "final": {
    "kind": "template",
    "template": "Weather: {{summary}}. Reminder created: {{created}}.",
    "bindings": {}
  },
  "limits": {
    "max_nodes": 12,
    "max_parallelism": 4,
    "deadline_ms": 15000,
    "max_output_bytes_per_node": 65536
  },
  "metadata": {
    "model_notes": "Use local deterministic execution only."
  }
}
```

Recommended required top-level fields:

| Field | Type | Purpose |
|---|---:|---|
| `schema_version` | string | Must equal `workflow.v1` for this design. |
| `workflow_id` | string | Stable model-generated ID for tracing. |
| `intent` | string | Human-readable summary for logs and approval UI. |
| `mode` | enum | `execute`, `dry_run`, `needs_clarification`, or `unsupported`. |
| `nodes` | array | Topologically sorted node declarations. |
| `final` | object | Deterministic return/rendering policy. |
| `limits` | object | Runtime caps. |
| `metadata` | object | Optional non-executable notes; never trusted for execution. |

`mode` semantics:

- `execute`: validate and execute.
- `dry_run`: validate and display plan; do not execute tools.
- `needs_clarification`: do not execute; display the question in `final`.
- `unsupported`: do not execute; display the reason in `final`.

### 5.3 Node object

Core v1 tool node:

```json
{
  "id": "get_weather",
  "kind": "tool",
  "tool": "weather_get_forecast",
  "depends_on": [],
  "input": {
    "location": "Hangzhou",
    "date": "2026-05-29"
  },
  "policy": {
    "timeout_ms": 5000,
    "retry": {
      "max_attempts": 2,
      "backoff_ms": 300,
      "retry_only_if_tool_error_is_retriable": true
    },
    "on_error": "abort"
  },
  "output_policy": {
    "store": true,
    "expose_to_final": true,
    "max_bytes": 32768,
    "redaction": "tool_default"
  }
}
```

Required node fields:

| Field | Type | Purpose |
|---|---:|---|
| `id` | string | Unique within workflow. Use snake_case. |
| `kind` | enum | `tool` in core v1. Add `const`, `transform`, `guard`, `fanout` later. |
| `tool` | string/null | Tool name for `tool` nodes. Null for non-tool nodes. |
| `depends_on` | array | Explicit dependencies not inferable from references, especially side-effect ordering. |
| `input` | JSON object | Literal input mixed with reference objects. |
| `policy` | object | Timeout, retry, and error policy. |
| `output_policy` | object | Storage, redaction, exposure, and size caps. |

Node IDs should match `^[a-z][a-z0-9_]{0,63}$`. Tool names should be provider-compatible and should avoid dots because some providers restrict tool names to letters, digits, `_`, and `-`. Prefer namespaced names such as `calendar_create_event` or `journal__search_entries`.

### 5.4 References

Node inputs can contain references to prior outputs or context values.

Reference object:

```json
{
  "$ref": {
    "source": "node",
    "node": "get_weather",
    "path": "/forecast/0/precipitation_probability"
  }
}
```

Supported reference sources:

| Source | Meaning |
|---|---|
| `node` | Output of a previous node. Requires `node` and `path`. |
| `context` | `ToolContext` or prompt-provided execution context. Requires `path`. |
| `user_input` | Structured user input extracted by the app before the model call. Requires `path`. |
| `item` | Current item inside a bounded `fanout` body. v1.1 only. |

Use **JSON Pointer** paths, not arbitrary JSONPath or JavaScript expressions. JSON Pointer is simpler to validate and safer to implement.

Examples:

```json
{
  "user_id": { "$ref": { "source": "context", "path": "/metadata/user_id" } },
  "event_title": "Bring umbrella",
  "rain_probability": { "$ref": { "source": "node", "node": "get_weather", "path": "/daily/0/rain_probability" } }
}
```

Literal escape hatch:

If a tool genuinely needs an input object with a top-level `$ref` key, the model must wrap it:

```json
{
  "$literal": {
    "$ref": "this is literal data, not a workflow reference"
  }
}
```

The executor unwraps `$literal` without resolving it.

### 5.5 Dependency rules

The validator must compute dependencies from two sources:

1. explicit `depends_on`; and
2. implicit references inside `input`, `final.bindings`, and future transform definitions.

Rules:

1. Every referenced node must exist.
2. Every referenced node must appear earlier in `nodes` if the model claims the array is topologically sorted.
3. The final computed graph must be acyclic.
4. A node may not depend on itself.
5. `depends_on` may include a node even if no input reference exists. This is needed for side-effect ordering.
6. If a node references another node, the runtime must treat that as a dependency even if `depends_on` omitted it.

### 5.6 Final result object

A workflow needs a deterministic final result because no second LLM call is allowed.

Recommended final kinds:

#### `value`

Return a resolved JSON value.

```json
{
  "kind": "value",
  "value": {
    "weather": { "$ref": { "source": "node", "node": "get_weather", "path": "" } },
    "event": { "$ref": { "source": "node", "node": "create_calendar_event", "path": "" } }
  }
}
```

#### `template`

Render a string using safe placeholder substitution. Placeholders must map to `bindings` values; they are not expressions.

```json
{
  "kind": "template",
  "template": "Tomorrow in {{city}}, rain probability is {{rain_probability}}%. Reminder created: {{event_title}}.",
  "bindings": {
    "city": "Hangzhou",
    "rain_probability": {
      "$ref": {
        "source": "node",
        "node": "get_weather",
        "path": "/daily/0/rain_probability"
      }
    },
    "event_title": {
      "$ref": {
        "source": "node",
        "node": "create_calendar_event",
        "path": "/title"
      }
    }
  }
}
```

#### `node_output`

Return the output of one node directly.

```json
{
  "kind": "node_output",
  "node": "search_entries",
  "path": "/results"
}
```

#### `message`

Use for `needs_clarification` or `unsupported`.

```json
{
  "kind": "message",
  "message": "I need the calendar date before I can create the reminder."
}
```

### 5.7 Example: nested workflow represented as DAG

Desired conceptual call:

```text
Workflow(
  Tool1(),
  Tool2(),
  Tool3(resultOfTool1, resultOfTool2)
)
```

DAG representation:

```json
{
  "schema_version": "workflow.v1",
  "workflow_id": "wf_example_join",
  "intent": "Run two independent tools and feed both outputs into a third tool.",
  "mode": "execute",
  "nodes": [
    {
      "id": "tool1_result",
      "kind": "tool",
      "tool": "tool1",
      "depends_on": [],
      "input": {},
      "policy": { "timeout_ms": 5000, "retry": { "max_attempts": 1, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
      "output_policy": { "store": true, "expose_to_final": false, "max_bytes": 65536, "redaction": "tool_default" }
    },
    {
      "id": "tool2_result",
      "kind": "tool",
      "tool": "tool2",
      "depends_on": [],
      "input": {},
      "policy": { "timeout_ms": 5000, "retry": { "max_attempts": 1, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
      "output_policy": { "store": true, "expose_to_final": false, "max_bytes": 65536, "redaction": "tool_default" }
    },
    {
      "id": "combined_result",
      "kind": "tool",
      "tool": "tool3",
      "depends_on": [],
      "input": {
        "first": { "$ref": { "source": "node", "node": "tool1_result", "path": "" } },
        "second": { "$ref": { "source": "node", "node": "tool2_result", "path": "" } }
      },
      "policy": { "timeout_ms": 5000, "retry": { "max_attempts": 1, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
      "output_policy": { "store": true, "expose_to_final": true, "max_bytes": 65536, "redaction": "tool_default" }
    }
  ],
  "final": {
    "kind": "node_output",
    "node": "combined_result",
    "path": ""
  },
  "limits": { "max_nodes": 10, "max_parallelism": 2, "deadline_ms": 15000, "max_output_bytes_per_node": 65536 },
  "metadata": {}
}
```

The executor runs `tool1_result` and `tool2_result` in parallel, then resolves both references and runs `combined_result`.

---

## 6. Optional schema extensions

Implement the core v1 first. Add the following only after the validator and executor are reliable.

### 6.1 `const` nodes

Purpose: give a stable ID to a reusable literal value.

```json
{
  "id": "target_city",
  "kind": "const",
  "tool": null,
  "depends_on": [],
  "input": { "value": "Hangzhou" },
  "policy": { "timeout_ms": 0, "retry": { "max_attempts": 0, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
  "output_policy": { "store": true, "expose_to_final": false, "max_bytes": 1024, "redaction": "none" }
}
```

### 6.2 `transform` nodes

Purpose: deterministic local data shaping without a tool call.

Allowed operations should be small and closed:

- `pick`: select fields by JSON Pointer.
- `object`: assemble object from literals/refs.
- `array`: assemble array from literals/refs.
- `template`: render a string from bindings.
- `join_strings`: concatenate strings with separator.
- `coalesce`: first non-null value.

Avoid arbitrary expressions in v1. Do not add JavaScript, regex-heavy DSLs, or unbounded computation on edge.

Example:

```json
{
  "id": "event_payload",
  "kind": "transform",
  "tool": null,
  "depends_on": [],
  "input": {
    "op": "object",
    "value": {
      "title": "Bring umbrella",
      "notes": {
        "$ref": {
          "source": "node",
          "node": "get_weather",
          "path": "/summary"
        }
      }
    }
  },
  "policy": { "timeout_ms": 100, "retry": { "max_attempts": 0, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
  "output_policy": { "store": true, "expose_to_final": false, "max_bytes": 4096, "redaction": "none" }
}
```

### 6.3 `guard` nodes

Purpose: deterministic branching without another LLM call.

Allowed condition operators:

- `exists`
- `equals`
- `not_equals`
- `greater_than`
- `less_than`
- `contains`
- `and`
- `or`
- `not`

Guard output should be a boolean object such as `{ "passed": true }`. Dependent nodes may use `run_if` to reference a guard.

Example:

```json
{
  "id": "rain_guard",
  "kind": "guard",
  "tool": null,
  "depends_on": [],
  "input": {
    "condition": {
      "op": "greater_than",
      "left": { "$ref": { "source": "node", "node": "get_weather", "path": "/daily/0/rain_probability" } },
      "right": 50
    }
  },
  "policy": { "timeout_ms": 100, "retry": { "max_attempts": 0, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
  "output_policy": { "store": true, "expose_to_final": false, "max_bytes": 1024, "redaction": "none" }
}
```

A later node may include:

```json
"run_if": { "$ref": { "source": "node", "node": "rain_guard", "path": "/passed" } }
```

### 6.4 Bounded `fanout` nodes

Purpose: handle runtime-determined arrays without another LLM call.

Example: search files, then read each returned file. The model cannot know the file IDs before execution, so a static DAG is insufficient unless the runtime supports bounded expansion.

Design rule: a `fanout` is syntactically nested but operationally expanded into a DAG at runtime.

```json
{
  "id": "read_matching_files",
  "kind": "fanout",
  "tool": null,
  "depends_on": ["search_files"],
  "input": {
    "foreach": { "$ref": { "source": "node", "node": "search_files", "path": "/items" } },
    "as": "file",
    "max_items": 5,
    "body": [
      {
        "id": "read_file",
        "kind": "tool",
        "tool": "files_read",
        "depends_on": [],
        "input": {
          "file_id": { "$ref": { "source": "item", "path": "/id" } }
        },
        "policy": { "timeout_ms": 5000, "retry": { "max_attempts": 1, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "continue_with_null" },
        "output_policy": { "store": true, "expose_to_final": true, "max_bytes": 32768, "redaction": "tool_default" }
      }
    ],
    "reduce": {
      "kind": "array",
      "from": "read_file"
    }
  },
  "policy": { "timeout_ms": 15000, "retry": { "max_attempts": 0, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true }, "on_error": "abort" },
  "output_policy": { "store": true, "expose_to_final": true, "max_bytes": 131072, "redaction": "tool_default" }
}
```

Fanout constraints:

1. `max_items` is required and capped by app policy.
2. Body node IDs are local names; expanded IDs should be deterministic, e.g. `read_matching_files[0].read_file`.
3. Fanout body must itself be acyclic.
4. Fanout should respect global `max_parallelism`.
5. Fanout outputs should be reduced deterministically.

---

## 7. Workflow JSON Schema strategy

### 7.1 Internal schema vs provider schema

Use two schema layers:

1. **Internal schema:** ergonomic for Swift decoding and local validation.
2. **Provider schema:** transformed into each provider’s strict subset.

For example, OpenAI strict function calling requires `additionalProperties: false` for each object and all properties listed as required, with optional fields represented via nullable types. Do not force the entire Swift model to be awkward just because one provider needs canonical strict form. Implement a provider adapter that canonicalizes the exported schema.

### 7.2 Minimum internal schema concepts

The schema builder in `ToolSchema.swift` should be expanded to support:

- strict object with `additionalProperties: false`;
- nullable types;
- enums;
- constant values;
- integer/number min/max;
- string min/max length;
- array min/max items;
- descriptions on every property;
- examples where provider supports them;
- reusable schema fragments if the provider supports them, or inlining if not.

### 7.3 Provider compatibility notes

Use the following conservative subset for the workflow schema sent to models:

- `type`
- `description`
- `properties`
- `required`
- `additionalProperties: false`
- `items`
- `enum`
- nullable primitive types, if supported
- bounded arrays where possible

Avoid relying on advanced JSON Schema features such as `if/then/else`, `dependentSchemas`, unrestricted `oneOf`, complex regex patterns, or custom formats in the provider-facing schema. Enforce those rules locally in `WorkflowValidator` instead.

---

## 8. Tool descriptor extensions

### 8.1 Add output schema

Current `ToolDescriptor` has only `inputSchema`. For workflow references and validation, add `outputSchema`.

Conceptual shape:

```swift
// Example API shape only, not implementation code.
public struct ToolDescriptor {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: ToolAnnotations?
    public var inputExamples: [JSONValue]?
}
```

Why output schema matters:

- lets validator check likely-valid reference paths;
- lets prompt explain outputs to the model;
- lets executor validate actual outputs;
- allows safer final rendering;
- improves eval diagnostics when the model references a nonexistent field.

### 8.2 Add tool annotations

Recommended annotations:

| Field | Type | Meaning |
|---|---:|---|
| `is_read_only` | bool | True if no external state changes. |
| `is_idempotent` | bool | True if repeated calls with same input are safe. |
| `side_effect` | enum | `none`, `local_write`, `network_read`, `network_write`, `destructive`, `external_message`, `payment`, `auth`. |
| `requires_user_approval` | bool | Runtime must prompt/confirm before execution unless pre-authorized. |
| `allowed_without_network` | bool | Whether tool can run offline. |
| `default_timeout_ms` | int | Runtime default. |
| `max_output_bytes` | int | Tool-specific cap. |
| `sensitive_output` | enum | `none`, `personal`, `credentials`, `private_content`, `unknown`. |
| `cache_policy` | enum | `none`, `memory`, `disk`, `session`. |
| `result_summary_hint` | string | How to summarize or project output for logs/final display. |

### 8.3 Tool descriptions need workflow-specific clarity

Update descriptions to include:

1. what the tool does;
2. when to use it;
3. when not to use it;
4. important parameter constraints;
5. output shape and important fields;
6. side effects;
7. whether the output is safe to expose in the final answer;
8. examples of valid inputs.

Bad description:

```text
Searches entries.
```

Good description:

```text
Search journal entries by semantic query and optional date range. Use when the workflow needs to retrieve existing user-written entries before summarizing, editing, or linking them. Do not use for web search or for creating new entries. Returns an object with `results`, where each result has `id`, `title`, `snippet`, `created_at`, and `score`. Snippets may contain private user content; expose only if the user requested it.
```

---

## 9. Required changes by Swift file

### 9.1 `Tool.swift`

Recommended changes:

1. Add optional/default `outputSchema` to `Tool`.
2. Add optional/default `annotations` to `Tool`.
3. Add optional/default `inputExamples` to `Tool`.
4. Keep `Input` and `Output` as `Codable & Sendable`.
5. Keep `call(_:in:)` unchanged.
6. Consider making `ToolCall.id` required for workflow-internal calls, while preserving backward compatibility for provider tool calls.
7. Add workflow-specific errors separately rather than overloading `ToolRegistryError`.

Backward-compatible conceptual API:

```swift
// Example API shape only.
extension Tool {
    public static var outputSchema: ToolSchema { .unknownObject }
    public static var annotations: ToolAnnotations { .default }
    public static var inputExamples: [JSONValue] { [] }
}
```

If the codebase cannot add default protocol members cleanly, define a second protocol such as `WorkflowToolMetadata` and let tools adopt it incrementally.

### 9.2 `ToolSchema.swift`

Recommended changes:

1. Add `strictObject(properties:required:)` that always emits `additionalProperties: false`.
2. Add `nullable(_:)`.
3. Add `stringEnum`, `integerEnum`, and generic enum helpers.
4. Add descriptions for objects, arrays, and fields.
5. Add bounded array helpers.
6. Add `unknownObject` fallback for tools without output schemas.
7. Add provider canonicalization support outside this file or as a companion type.

Important: keep this builder small enough to remain understandable. The workflow validator can enforce constraints that the model-facing schema cannot express.

### 9.3 `ToolDescriptor.swift`

Recommended changes:

1. Add `outputSchema: JSONValue?`.
2. Add `annotations: ToolAnnotations?`.
3. Add `inputExamples: [JSONValue]?`.
4. Add `schemaVersion` if descriptor evolution becomes complex.
5. Preserve Codable compatibility by making new fields optional when decoding older descriptors.

### 9.4 `ToolRegistry.swift`

Recommended changes:

1. Store extended descriptor metadata.
2. Add `descriptor(for name: String)`.
3. Add `contains(name:)`.
4. Add `validateAllowedTools(_ names: Set<String>)` or keep allowlist validation in workflow validator.
5. Add a convenience dispatch that accepts `ToolCall` and returns `JSONValue`, while keeping the current `Data` method.
6. Do not put DAG scheduling inside `ToolRegistry`; create a separate `WorkflowExecutor` so the registry remains a tool dispatch primitive.

### 9.5 New files to add

Add these new files rather than bloating the four existing files:

| File | Responsibility |
|---|---|
| `WorkflowSpec.swift` | Codable models for workflow, node, reference, policies, final result. |
| `WorkflowSchema.swift` | JSON Schema for the synthetic workflow tool / structured response. |
| `WorkflowValidator.swift` | Static validation: schema, graph, refs, limits, policies. |
| `WorkflowExecutor.swift` | Topological scheduling, reference resolution, tool dispatch, retry, cancellation. |
| `WorkflowResultStore.swift` | Stores node outputs, applies redaction and size caps. |
| `WorkflowFinalRenderer.swift` | Renders `value`, `template`, `node_output`, and `message`. |
| `WorkflowErrors.swift` | Workflow-specific validation/execution errors. |
| `WorkflowTrace.swift` | Execution trace and node-level telemetry. |
| `WorkflowPromptBuilder.swift` | Builds provider-agnostic prompt/tool catalog for one-shot planning. |
| `ProviderSchemaAdapter.swift` | Converts internal schemas to provider-specific strict schemas. |

---

## 10. Workflow validation design

Validation should happen before any tool runs.

### 10.1 Static validation checklist

The validator must check:

1. `schema_version` supported.
2. `workflow_id` valid and bounded length.
3. `mode` known.
4. Node count within `limits.max_nodes` and app hard cap.
5. Node IDs unique and valid.
6. Tool names exist in `ToolRegistry`.
7. Tool names are allowed in current view/context.
8. Node kinds are supported by this runtime.
9. Explicit dependencies exist.
10. References point to allowed sources.
11. Node references point to existing predecessor nodes.
12. Computed graph is acyclic.
13. `nodes` array is topologically sorted, or executor re-sorts after validation.
14. `final` references are valid.
15. Per-node timeout does not exceed tool/app caps.
16. Retry policy bounded.
17. Output byte caps bounded.
18. Total deadline bounded.
19. Side-effect tools comply with approval policy.
20. Mutating/destructive tools have explicit ordering if order matters.
21. Workflow does not exceed max parallelism.
22. Workflow does not request unsupported final rendering.

### 10.2 Type validation

Perform type validation in two phases:

#### Before execution

- Validate literal parts of each node input against the tool input schema where possible.
- Validate reference source existence.
- If predecessor output schemas are known, check reference paths and expected types where possible.

#### At runtime before each node

- Resolve references.
- Assemble concrete JSON input.
- Validate the complete input against the tool’s input schema.
- Dispatch tool only after validation passes.

#### After each node

- Validate output against `outputSchema` if known.
- Apply output size cap.
- Apply redaction policy.
- Store result or failure.

### 10.3 Cycle detection and topological levels

The executor should compute levels even if the model provided nodes in topological order.

Example:

```text
Level 0: A, B
Level 1: C(A,B), D(B)
Level 2: E(C,D)
```

Run all nodes in a level concurrently subject to:

- `limits.max_parallelism`;
- tool-specific concurrency limits;
- side-effect ordering rules;
- app-level resource constraints.

---

## 11. Execution semantics

### 11.1 Node lifecycle

Each node should pass through:

```text
pending → ready → running → succeeded
                       ├── failed_retryable → running
                       ├── failed_terminal
                       ├── skipped
                       └── cancelled
```

### 11.2 Input resolution

For each ready node:

1. Traverse `input` recursively.
2. Replace reference objects with values from result store/context/user input.
3. Preserve `$literal` values without resolving.
4. Fail if a required referenced node failed and no `on_error` policy supplies a default.
5. Validate resolved input against the tool schema.

### 11.3 Retry policy

Recommended per-node retry object:

```json
{
  "max_attempts": 2,
  "backoff_ms": 300,
  "retry_only_if_tool_error_is_retriable": true
}
```

Rules:

1. `max_attempts` means total attempts, not retries after the first attempt.
2. The executor should consult `ToolError.isRetriable` when available.
3. Registry decoding/encoding errors are usually not retriable.
4. Validation errors are not retriable.
5. Timeouts may be retriable only if the tool annotation allows it.

### 11.4 Error policies

Recommended `on_error` enum:

| Value | Meaning |
|---|---|
| `abort` | Stop workflow and return failure. Default. |
| `continue_with_null` | Store null output and allow dependents that accept null. |
| `continue_with_default` | Store `default_output`. Requires default. |
| `skip_dependents` | Mark this node failed and skip dependent subgraph. |

Avoid `ask_llm` or `repair_with_llm`; those violate the one-shot goal.

### 11.5 Cancellation

The executor must support cancellation through Swift task cancellation. On cancellation:

1. stop scheduling new nodes;
2. cancel running child tasks where possible;
3. return partial trace;
4. do not run dependent side-effect nodes after cancellation.

---

## 12. Safety and permission model

### 12.1 Why workflow-level safety is different

A single workflow may contain multiple side-effect tools. A model could hide a destructive operation late in the DAG. Therefore, approvals cannot be based only on the first tool call.

### 12.2 Approval strategy

Before execution, compute a workflow-level approval summary:

```text
This workflow will:
- read local journal entries;
- create one calendar event;
- send zero external messages;
- perform no destructive operations.
```

If any node requires approval and the app does not have pre-authorization, stop before execution and request approval. Do not partially execute read nodes first unless the policy allows pre-approval reads.

### 12.3 Side-effect ordering

Mutating tools should be ordered explicitly with `depends_on` when:

- two nodes update the same resource;
- one node sends a notification about another node’s result;
- a destructive node depends on a prior validation/check;
- user approval applies to a specific proposed mutation.

### 12.4 Sensitive dataflow

Add dataflow checks later if needed:

- outputs marked `credentials` may not be passed to network-write tools;
- private user content may not be exposed in final templates unless user requested it;
- sensitive node outputs should be redacted in logs and traces;
- the result store should keep full values only in memory unless app policy permits persistence.

### 12.5 Prompt injection defense

Treat tool outputs as untrusted data. A retrieved document or web result must not be allowed to alter the workflow after validation. Since the graph is fixed before execution, this design naturally reduces prompt-injection risk compared with iterative model loops. Still, unsafe data can flow into side-effect tools, so enforce policy at dataflow boundaries.

---

## 13. Prompting and model contract

### 13.1 What the model should see

The model should receive:

1. user request;
2. execution context summary;
3. allowed tool catalog;
4. workflow schema;
5. strict instruction to return one workflow only;
6. examples of valid workflows;
7. constraints about no placeholders, no forward references, no hidden second LLM step.

### 13.2 Tool catalog format

Use compact but precise descriptors:

```json
{
  "name": "journal_search_entries",
  "description": "Search journal entries by semantic query and optional date range. Use when retrieving existing user entries. Do not use for web search or creating entries. Returns results with id, title, snippet, created_at, score. Snippets may contain private content.",
  "input_schema": { "type": "object", "properties": {}, "required": [], "additionalProperties": false },
  "output_schema": { "type": "object", "properties": {}, "required": [], "additionalProperties": false },
  "annotations": {
    "is_read_only": true,
    "side_effect": "none",
    "requires_user_approval": false
  },
  "input_examples": []
}
```

### 13.3 System instruction sketch

Use wording like this in the model request:

```text
You are a workflow planner for an edge-device agent. You do not execute tools. You return exactly one JSON object matching WorkflowSpec.

The runtime will execute the workflow locally without asking you for another message. Therefore:
- Include every required tool call in the workflow.
- Use references for values that come from earlier node outputs.
- Do not invent placeholder IDs for values that must come from a tool result.
- Put independent tool calls in separate nodes with no dependencies so they can run in parallel.
- Add dependencies when a node needs another node's output or when side effects require ordering.
- If the request cannot be completed in one deterministic workflow, return mode `needs_clarification` or `unsupported` with a user-facing message.
- The final answer must be deterministic: node output, JSON value, or template with bindings.
```

### 13.4 Model output policy

The model must not return prose around the workflow. The workflow JSON is the entire response or the argument of the single synthetic `workflow_run` tool call.

---

## 14. Provider integration modes

### 14.1 Structured-output mode

Use when the provider supports JSON schema response formats. The model response is directly decoded into `WorkflowSpec`.

Pros:

- no fake tool needed;
- direct structured result;
- easy to reason about.

Cons:

- provider schema subset differences;
- some providers are stricter about optional fields.

### 14.2 Synthetic workflow tool mode

Expose one provider tool:

```text
workflow_run(spec: WorkflowSpec)
```

The model “calls” only this synthetic tool. The host intercepts this provider tool call and runs the local workflow executor.

Pros:

- aligns with current tool infrastructure vocabulary;
- works well with providers tuned for function/tool calling;
- enforces the desired mental model: `Workflow(...)`.

Cons:

- underlying tools are not provider tools, so the prompt must include the tool catalog as context;
- provider may still try to return text unless strongly instructed or forced.

### 14.3 Do not expose underlying tools directly in one-shot mode

If the provider sees `Tool1`, `Tool2`, and `Tool3` as direct callable tools, it may enter the old iterative tool-call pattern. In one-shot workflow mode, expose underlying tools only as catalog data, not as provider-executable tools.

---

## 15. Alternative schema proposals for experiments

The recommended schema is Proposal A. The other proposals are included because they are fundamentally different enough to A/B test.

### Proposal A — Explicit DAG JSON IR

This is the main recommendation.

Core idea:

```json
{
  "nodes": [
    { "id": "a", "kind": "tool", "tool": "tool1", "input": {} },
    { "id": "b", "kind": "tool", "tool": "tool2", "input": {} },
    { "id": "c", "kind": "tool", "tool": "tool3", "input": { "x": { "$ref": { "source": "node", "node": "a", "path": "" } }, "y": { "$ref": { "source": "node", "node": "b", "path": "" } } } }
  ]
}
```

Strengths:

- easiest to validate;
- easiest to schedule;
- easiest to audit;
- naturally supports parallel levels;
- safest for edge devices;
- maps directly to current `ToolCall` and `ToolRegistry`.

Weaknesses:

- verbose;
- dynamic fanout requires an extension;
- complex conditional logic becomes clunky.

Use for v1 production.

### Proposal B — SSA/dataflow binding schema

Core idea: the model emits a list of named bindings. Each binding is a pure call expression. The compiler derives the DAG.

Example:

```json
{
  "schema_version": "workflow.ssa.v1",
  "let": [
    { "name": "weather", "call": "weather_get_forecast", "args": { "city": "Hangzhou", "date": "2026-05-29" } },
    { "name": "calendar", "call": "calendar_create_event", "args": { "title": "Bring umbrella", "notes": { "$var": "weather.summary" } } }
  ],
  "return": { "$var": "calendar" }
}
```

Strengths:

- shorter than explicit node objects;
- familiar to models because it resembles code;
- readable for humans;
- dependencies are inferred from `$var` references.

Weaknesses:

- less explicit scheduling metadata;
- policy/timeout/error handling has to be attached awkwardly;
- compiler must prevent it from becoming a general expression language;
- references such as `weather.summary` are less robust than JSON Pointer.

Use as an experiment if token cost of Proposal A is too high.

### Proposal C — Constrained workflow bytecode

Core idea: the model emits a tiny instruction list. The runtime interprets bytecode instructions such as `CALL`, `PICK`, `JOIN`, `IF`, `MAP`, and `RETURN`.

Example:

```json
{
  "schema_version": "workflow.bytecode.v1",
  "instructions": [
    { "op": "CALL", "out": "w", "tool": "weather_get_forecast", "args": { "city": "Hangzhou" } },
    { "op": "PICK", "out": "p", "from": "w", "path": "/daily/0/rain_probability" },
    { "op": "IF", "cond": { "op": "GT", "left": { "$var": "p" }, "right": 50 }, "then": [
      { "op": "CALL", "out": "e", "tool": "calendar_create_event", "args": { "title": "Bring umbrella" } }
    ] },
    { "op": "RETURN", "value": { "rain_probability": { "$var": "p" } } }
  ]
}
```

Strengths:

- compact;
- handles conditionals and maps more naturally;
- closer to Anthropic’s “let code orchestrate tools” philosophy, but without arbitrary code.

Weaknesses:

- harder to validate statically;
- harder to make provider JSON Schema strict;
- higher implementation risk;
- easier for the DSL to grow into an unsafe language.

Use only for comparison after Proposal A is stable.

### Recommendation for experiments

Evaluate A vs B first. Do not evaluate C until the executor has mature validation, telemetry, and safety policies.

Metrics:

- valid schema rate;
- valid graph rate;
- correct tool selection rate;
- correct dependency/reference rate;
- execution success rate;
- latency;
- tokens in prompt and completion;
- final answer usefulness;
- permission/safety violation rate;
- pass@1 and pass^3 on replayable tasks.

---

## 16. Evals and test harness

### 16.1 Unit tests

Test validator failures:

- duplicate node ID;
- missing tool;
- disallowed tool;
- unknown node kind;
- forward reference;
- cycle;
- missing final reference;
- invalid JSON Pointer;
- invalid literal input;
- retry policy too large;
- timeout too large;
- side-effect tool without approval;
- output cap too large.

### 16.2 Executor tests with fake tools

Create fake tools:

- read-only success tool;
- slow tool;
- retryable failure then success;
- terminal failure;
- large output tool;
- sensitive output tool;
- mutating side-effect tool;
- tool with output schema mismatch.

Verify:

- topological order;
- parallelism;
- cancellation;
- retry counts;
- error policy behavior;
- reference resolution;
- final rendering;
- trace content.

### 16.3 Model evals

Build a dataset of realistic user requests and expected workflow properties.

Example eval assertions:

- request “search my last three journal entries and summarize titles” should call `journal_search_entries` before any read/details tool;
- request requiring two independent reads should produce parallel independent nodes;
- request requiring output of node A for node B should not use placeholders;
- request involving mutation should include explicit final side-effect node and require approval;
- impossible requests should return `needs_clarification` or `unsupported`.

### 16.4 Replay tests

Store:

- prompt input;
- model workflow output;
- validation result;
- fake tool outputs;
- final workflow result;
- trace.

This lets the team compare model versions and schema variants without hitting real tools.

---

## 17. Telemetry and debugging

A workflow trace should include:

| Field | Purpose |
|---|---|
| `workflow_id` | Correlate logs. |
| `schema_version` | Debug migrations. |
| `node_id` | Per-node status. |
| `tool` | Tool invoked. |
| `state` | Pending/running/succeeded/failed/skipped. |
| `started_at`, `ended_at` | Latency. |
| `attempt_count` | Retry diagnostics. |
| `resolved_input_summary` | Redacted summary, not raw secrets. |
| `output_summary` | Redacted/capped output summary. |
| `error` | Sanitized error. |
| `dependency_ids` | Graph debugging. |
| `approval_status` | Permission debugging. |

Do not log raw private outputs unless the app has explicit debug consent.

---

## 18. Migration plan

### Phase 1 — Metadata expansion

- Add output schema and annotations to descriptors.
- Keep existing tools working.
- Update a few representative tools with good output schemas and examples.

### Phase 2 — Workflow models and validator

- Add `WorkflowSpec.swift` and `WorkflowValidator.swift`.
- Implement schema decoding and static validation.
- Add unit tests for invalid workflows.
- No execution yet.

### Phase 3 — Executor with fake tools

- Add `WorkflowExecutor.swift` and result store.
- Run fake tools only.
- Verify topological levels, refs, retry, and final rendering.

### Phase 4 — Executor with real registry

- Connect executor to `ToolRegistry.call`.
- Add resolved input validation before dispatch.
- Add output validation after dispatch.
- Add workflow trace.

### Phase 5 — Prompt integration

- Add `WorkflowPromptBuilder`.
- Add synthetic `workflow_run` tool mode or structured-output mode.
- Include compact tool catalog.
- Add example workflows.

### Phase 6 — Safety and approvals

- Implement workflow-level approval summary.
- Enforce side-effect policy before execution.
- Add redaction policy.

### Phase 7 — Optional extensions

- Add `transform`.
- Add `guard` and `run_if`.
- Add bounded `fanout`.
- Compare Proposal A vs Proposal B.

---

## 19. Implementation guidance for the coding agent

### 19.1 Keep the public tool API stable

Do not rewrite every tool. Existing tools should continue to compile with default metadata.

### 19.2 Keep workflow concerns separate

Do not put DAG execution inside `ToolRegistry`. The registry should remain a typed dispatch mechanism. The workflow layer should own graph validation, scheduling, and result storage.

### 19.3 Fail closed

If validation is uncertain, fail before running tools. Especially fail closed for:

- unknown tool;
- unknown node kind;
- unapproved mutation;
- invalid reference;
- missing dependency;
- tool input validation error;
- unsupported final renderer;
- excessive resource request.

### 19.4 Prefer deterministic local behavior

Do not add `repairWithLLM`, `askLLM`, or `summarizeWithLLM` to the executor. If later the product wants a second model call, make that a separate product mode, not the one-shot edge workflow mode.

### 19.5 Make examples first-class

Provider-facing tool and workflow examples should live near the schema definitions. Modern LLMs use examples heavily, and examples make regressions easier to test.

### 19.6 Validate after resolving references

A workflow can look valid before execution but produce an invalid input after references resolve. Always validate concrete input immediately before calling the underlying tool.

### 19.7 Make output schemas incremental

Output schemas are strongly recommended but should not block migration. Start with high-value tools and mark unknown outputs as `unknownObject`. Runtime reference checks will be weaker until output schemas improve.

### 19.8 Put caps everywhere

At minimum:

- max nodes;
- max fanout items;
- max parallelism;
- max workflow deadline;
- max node timeout;
- max output bytes per node;
- max final output bytes;
- max retries.

---

## 20. Suggested strict WorkflowSpec skeleton

This is a conceptual provider-facing schema skeleton, not the final generated schema. The actual schema should be built by `WorkflowSchema.swift` and canonicalized by `ProviderSchemaAdapter`.

```json
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "schema_version": {
      "type": "string",
      "enum": ["workflow.v1"],
      "description": "Workflow schema version. Must be workflow.v1."
    },
    "workflow_id": {
      "type": "string",
      "description": "Unique trace ID for this planned workflow."
    },
    "intent": {
      "type": "string",
      "description": "Brief user-visible explanation of what the workflow will do."
    },
    "mode": {
      "type": "string",
      "enum": ["execute", "dry_run", "needs_clarification", "unsupported"],
      "description": "Whether to execute, show plan only, ask user for clarification, or report unsupported."
    },
    "nodes": {
      "type": "array",
      "description": "Topologically sorted workflow nodes.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "id": { "type": "string" },
          "kind": { "type": "string", "enum": ["tool"] },
          "tool": { "type": ["string", "null"] },
          "depends_on": { "type": "array", "items": { "type": "string" } },
          "input": { "type": "object" },
          "policy": { "type": "object" },
          "output_policy": { "type": "object" }
        },
        "required": ["id", "kind", "tool", "depends_on", "input", "policy", "output_policy"]
      }
    },
    "final": {
      "type": "object",
      "description": "Deterministic final result renderer."
    },
    "limits": {
      "type": "object",
      "description": "Workflow resource limits."
    },
    "metadata": {
      "type": "object",
      "description": "Non-executable planning notes."
    }
  },
  "required": ["schema_version", "workflow_id", "intent", "mode", "nodes", "final", "limits", "metadata"]
}
```

The real provider schema must define `policy`, `output_policy`, `final`, `limits`, and reference objects in full. Keep the provider schema explicit even if the Swift Codable model uses optional fields.

---

## 21. Example end-to-end workflow

User request:

```text
Find the latest journal entry about my thesis, then create a task reminding me to review it tomorrow.
```

Assumed allowed tools:

- `journal_search_entries`
- `tasks_create_task`

Workflow:

```json
{
  "schema_version": "workflow.v1",
  "workflow_id": "wf_thesis_review_task_001",
  "intent": "Search for the most recent thesis-related journal entry and create a review task for tomorrow.",
  "mode": "execute",
  "nodes": [
    {
      "id": "search_thesis_entry",
      "kind": "tool",
      "tool": "journal_search_entries",
      "depends_on": [],
      "input": {
        "query": "thesis",
        "sort": "created_at_desc",
        "limit": 1
      },
      "policy": {
        "timeout_ms": 5000,
        "retry": { "max_attempts": 2, "backoff_ms": 300, "retry_only_if_tool_error_is_retriable": true },
        "on_error": "abort"
      },
      "output_policy": {
        "store": true,
        "expose_to_final": false,
        "max_bytes": 32768,
        "redaction": "tool_default"
      }
    },
    {
      "id": "create_review_task",
      "kind": "tool",
      "tool": "tasks_create_task",
      "depends_on": [],
      "input": {
        "title": "Review thesis journal entry",
        "due_date": "2026-05-29",
        "related_entry_id": {
          "$ref": {
            "source": "node",
            "node": "search_thesis_entry",
            "path": "/results/0/id"
          }
        },
        "notes": {
          "$ref": {
            "source": "node",
            "node": "search_thesis_entry",
            "path": "/results/0/title"
          }
        }
      },
      "policy": {
        "timeout_ms": 5000,
        "retry": { "max_attempts": 1, "backoff_ms": 0, "retry_only_if_tool_error_is_retriable": true },
        "on_error": "abort"
      },
      "output_policy": {
        "store": true,
        "expose_to_final": true,
        "max_bytes": 32768,
        "redaction": "tool_default"
      }
    }
  ],
  "final": {
    "kind": "template",
    "template": "Created task '{{task_title}}' for {{due_date}} linked to journal entry '{{entry_title}}'.",
    "bindings": {
      "task_title": {
        "$ref": {
          "source": "node",
          "node": "create_review_task",
          "path": "/title"
        }
      },
      "due_date": {
        "$ref": {
          "source": "node",
          "node": "create_review_task",
          "path": "/due_date"
        }
      },
      "entry_title": {
        "$ref": {
          "source": "node",
          "node": "search_thesis_entry",
          "path": "/results/0/title"
        }
      }
    }
  },
  "limits": {
    "max_nodes": 6,
    "max_parallelism": 2,
    "deadline_ms": 15000,
    "max_output_bytes_per_node": 65536
  },
  "metadata": {}
}
```

Note: this example intentionally uses a deterministic template. It does not ask the model to summarize the journal entry after retrieval.

---

## 22. Open design decisions

The coding agent should make these decisions explicit in code comments or architecture notes:

1. **Provider mode:** structured output or synthetic workflow tool? Recommendation: implement both adapters, start with synthetic workflow tool if the current product is already tool-call oriented.
2. **Strict schema generation:** hand-written JSON schema or generated from Swift models? Recommendation: builder-generated schema plus snapshot tests.
3. **Output schema migration:** require every tool to define output schema now or allow `unknownObject`? Recommendation: allow unknown but warn in validation telemetry.
4. **Approval UI:** show entire workflow before execution or only side-effect nodes? Recommendation: show summary plus expandable node list.
5. **Final answer:** template only or JSON value too? Recommendation: support `template`, `value`, `node_output`, and `message`.
6. **Dynamic fanout:** v1 or v1.1? Recommendation: v1.1 after core static DAG is stable.
7. **Transform nodes:** built-in node kind or ordinary tools? Recommendation: built-in for small deterministic operations; ordinary tools for complex business logic.

---

## 23. Definition of done

The workflow feature is ready when:

1. The model can produce a valid `WorkflowSpec` in one request for at least 90% of representative eval prompts.
2. The validator rejects malformed, cyclic, unsafe, or disallowed workflows before execution.
3. The executor runs independent nodes concurrently and dependent nodes in correct order.
4. Resolved inputs are validated before tool dispatch.
5. Tool outputs are stored, capped, optionally redacted, and available to later nodes.
6. Final results render without another LLM call.
7. Workflow-level approval stops unsafe side effects before any mutation happens.
8. The trace is sufficient to debug every node execution.
9. Existing tools continue to work without large rewrites.
10. Proposal A has baseline eval metrics, and Proposal B can be compared later if desired.

---

## 24. Final recommendation

Build Proposal A first: **explicit DAG JSON IR with references**.

It best matches the current Swift infrastructure, gives the edge runtime deterministic control, supports parallelism, and avoids the security risk of arbitrary model-generated code. Add `outputSchema`, tool annotations, a workflow validator, and a workflow executor as separate layers. Then evaluate a shorter SSA-style schema only if token cost or model usability becomes a bottleneck.
