# Agent hooks

An agent's own lifecycle hooks are the most reliable evidence about its
state, and the engineering invariants already rank "full official lifecycle
reports" first. telar does not depend on them: the proxy and the screen keep
working when no hook is installed, and a report expires like every other
evidence so a silent hook hands control back.

## End-to-end path

```text
telar integration install claude
        |
~/.claude/settings.json  hooks.{SessionStart,UserPromptSubmit,Stop,Notification,SessionEnd}
        += { type = command, command = "<telar> hook claude", timeout = 5 }

Claude Code fires a hook inside the pane
        |
telar hook claude   (stdin JSON; TELAR_PANE_ID + TELAR_PANE_GENERATION from the env)
        |
hook.mapClaudeHook -> { state, session }
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

## Pi

Pi has no hook files; its lifecycle reaches extensions as events. `telar
integration install pi` writes `~/.pi/agent/extensions/telar.ts` (bundled
from `src/cli/integration/pi.ts`) with the Telar executable path filled in.
The extension does nothing outside a Telar pane; inside one it runs
`telar hook pi` with a small JSON payload on each event:

```text
Pi extension event
        |
{ event, session_id, idle }  --stdin-->  telar hook pi
        |
hook.mapPiHook -> { state, session }
        |
schema.report_agent (same path as Claude Code from here)
```

| Pi event | Report |
| --- | --- |
| `session_start` | `ready` + session reference |
| `agent_start` | `working` |
| `agent_settled` | `ready` (projected as `done` until seen) |
| `ui_prompt_start` | `blocked` |
| `ui_prompt_end` | `ready` when Pi was idle, else `working` |
| `session_shutdown` | `exited` |

Pi renders no permission prompts of its own, so `blocked` only comes from
extension dialogs, which is exactly what `ui_prompt_start` reports. The
session reference is Pi's UUIDv7 session id, which `pi --session <id>`
resolves for restore. Uninstall deletes the file only when it starts with
the Telar marker line, so a user's own extension at that path is never
touched.

## Ownership

`telar hook` never fails loudly: outside a pane, with a malformed payload or
an unreachable runtime it exits 0, so the agent is unaffected. It sends one
bounded request and exits.

The runtime keeps the report as `Agent.report`, the first evidence
`chooseEvidence` consults while it is valid. A `working` report expires with
`working_expiry_ms`, other states with `settled_expiry_ms`; `applyProcess`
clears it when a different process takes the pane. Sounds follow the same
transition rule as screen evidence.

`telar integration` edits only the five event arrays it owns, adds an entry
once per event, removes only entries whose command ends in ` hook claude`,
and rewrites the file atomically with two-space indentation. Other settings
and other hooks are untouched.

## Proof

- `src/backend/agent/tracker.zig` proves precedence over screen evidence,
  `exited` withdrawal and expiry.
- `src/backend/runtime/entrypoints/requests/report_agent.zig` proves the
  reply contract.
- `src/cli/hook.zig` proves the event mapping and subagent filtering for
  Claude Code, the Pi event mapping, and that parsed reports own their
  session reference.
- `src/cli/integration.zig` proves idempotent install and selective removal
  for Claude Code, and rendering, marker detection and atomic owner-only
  installation for the Pi extension.
- `src/core/schema_contract_test.zig` pins the `report_agent` bytes.
