# Agent engine

`runtime.engine` gives the runtime one headless agent it can ask questions
without opening a pane: Pi in RPC mode, or any command that speaks the same
JSON-lines contract. Its only feature today is the
[command suggestion](suggest-command.md) palette; session titles keep their
own one-shot `agent_descriptions` command and never touch the engine. Every
request carries a `Purpose` that says who asked, so replies route without
runtime state.

## End-to-end path

```text
config.lua  runtime.engine = { command = { "pi", "--mode", "rpc", ... }, ... }
        |
config.root.parseEngine -> RuntimeSnapshot.engine (CommandSpec) + engine_idle_timeout_ms
        |
telar server: Launch.engine_options -> runtime Options.engine
        |
Resources.engine (resources/engine.zig) starts the engine.Service actor
        |
prefix+? in a client -> suggest_command -> routeSuggestCommand
        |
suggestion.buildPrompt -> engine.Prompt (purpose = suggestion{client, request})
        |
Service.submit (bounded ring, never blocks the runtime)
        |
actor: Session.open (spawn on first prompt, cwd "/") -> rpc.encodePrompt ->
       records until agent_settled -> get_last_assistant_text -> Response
        |
Event.engine_response (observation path) -> AgentEvents.handleEngineResponse
        |
deliverSuggestion -> command_suggestion queued for that client, clients pumped
```

## Ownership and budgets

The runtime owns the engine: it survives every client and its replies are
routed by the `Purpose` carried in each request, so the runtime keeps no
per-request state. Prompts and replies are fixed-size (`max_prompt_bytes`,
`max_reply_bytes`); the request and response rings hold
`max_pending_requests` entries and `submit` refuses instead of blocking. A
refused request answers its feature with a status instead of waiting.

Everything runs on the observation path. The actor parses one JSON record at
a time with the runtime allocator, drops records above `rpc.max_line_bytes`
whole, and applies one deadline (`timeout_ms`) to the whole exchange. A
timeout, a rejected prompt, a closed pipe or an unreadable stream kills the
child so the next prompt starts a fresh process; an oversized or empty reply
keeps the child and reports `invalid_output`.

The child is killed after `idle_timeout_ms` without prompts. The engine runs
no timer: the agent maintenance tick asks for an idle check, and the request
is queued only while a child is alive and no check is pending.

Prompts never enter process arguments and the child starts from `/`, so
project context files, trust prompts and tool access are exactly the flags
written in `config.lua`. Configuring the engine is a privacy opt-in: each
feature documents what its prompt carries.

## Contract with Pi

Records are LF-delimited JSON objects. The engine sends
`{"type":"prompt","message":...}` and `{"type":"get_last_assistant_text"}`
and acts on four records: the prompt reply (`type = "response"`,
`command = "prompt"`, `success`), `agent_settled`, and the
`get_last_assistant_text` reply whose `data.text` is the answer. Every other
event is skipped without inspection, so a newer Pi that adds events keeps
working, and a Pi that renames one of these four degrades to a timeout.

## Proof

- `src/backend/engine/rpc.zig` proves encoding, escaping and record
  classification.
- `src/backend/engine/session.zig` proves the dialogue against a shell fake
  of the RPC contract: settled text, timeout, rejection, child exit, empty
  and oversized replies.
- `src/backend/engine/service.zig` proves child reuse, idle kill, which
  failures discard the child, missing binary, ring capacity and actor
  shutdown.
- `src/backend/runtime/resources/engine.zig` and `worker_lifecycle.zig` prove
  ownership rollback and teardown order.
- `src/frontend/config/root.zig` proves parsing and bounds.
