# Agent hooks

An agent's own lifecycle hooks are the most reliable evidence about its
state, and the engineering invariants already rank "full official lifecycle
reports" first. telar does not depend on them: the proxy and the screen keep
working when no hook is installed, and a report expires like every other
evidence so a silent hook hands control back.

## End-to-end path

```text
telar integration install claude|codex
        |
~/.claude/settings.json or ~/.codex/hooks.json
        hooks.<owned event> += { type = command, command = "<telar> hook <agent>", timeout = bounded }

Claude Code or Codex fires a hook inside the pane
        |
telar hook <agent>   (stdin JSON; TELAR_PANE_ID + TELAR_PANE_GENERATION from the env)
        |
hook.mapClaudeHook or hook.mapCodexHook -> { state, session }
        |
schema.report_agent -> routeReportAgent -> ReportAgentHandler
        |
Tracker.observeReport -> Agent.applyReport (Evidence source lifecycle_report)
        |                  + Agent.applySessionReference when the hook carried one
        |
reproject -> agent_snapshot; working -> done publishes the agent sound;
a new session reference marks the session checkpoint dirty
```

## Mapping

| Claude Code event | Report |
| --- | --- |
| `SessionStart` | `ready` + session reference |
| `UserPromptSubmit` | `working` |
| `Stop` | `ready` (projected as `done` until seen) |
| `Notification` `permission_prompt`, `elicitation_*`, `agent_needs_input` | `blocked` |
| `Notification` `idle_prompt` | `ready` |
| `SessionEnd` | `exited`: the report is withdrawn, weaker evidence decides |
| any event with `agent_id` (subagent) | ignored |

| Codex event | Report |
| --- | --- |
| `SessionStart` | `ready` + session reference |
| `SessionStart` with source `compact` | `working` + session reference |
| `UserPromptSubmit` | `working` |
| `PermissionRequest` | `blocked` |
| `PostToolUse` | `working`, recovering from a resolved permission request |
| `Stop`, `Interrupt` | `ready` |
| `SessionEnd` | `exited`: the report is withdrawn, weaker evidence decides |
| any event with `agent_id` (subagent) | ignored |

## Ownership

`telar hook` never fails loudly: outside a pane, with a malformed payload or
an unreachable runtime it exits 0, so the agent is unaffected. It sends one
bounded request and exits.

The runtime keeps the report as `Agent.report`, the first evidence
`chooseEvidence` consults while it is valid. A `working` report expires with
`working_expiry_ms`, other states with `settled_expiry_ms`; `applyProcess`
clears it when a different process takes the pane. Sounds follow the same
transition rule as screen evidence.

`telar integration` edits only the event arrays owned by the selected agent,
adds an entry once per event, removes only entries whose command ends in
` hook claude` or ` hook codex`, and rewrites the file atomically with
two-space indentation. Other settings and hooks are untouched. Codex uses
`$CODEX_HOME/hooks.json` when `CODEX_HOME` is set and `~/.codex/hooks.json`
otherwise. Codex asks the user to trust the new hook definitions; telar does
not write Codex's trust state or bypass that check. Claude hooks use a
five-second timeout. Codex hooks use three seconds, the maximum Codex accepts
for `SessionEnd` and `Interrupt`.

## Proof

- `src/backend/agent/tracker.zig` proves precedence over screen evidence,
  `exited` withdrawal and expiry.
- `src/backend/runtime/entrypoints/requests/report_agent.zig` proves the
  reply contract.
- `src/cli/hook.zig` proves the event mapping and subagent filtering.
- `src/cli/integration.zig` proves idempotent install and selective removal.
- `src/core/schema_contract_test.zig` pins the `report_agent` bytes.
