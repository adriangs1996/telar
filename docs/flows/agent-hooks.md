# Agent hooks

An agent's own hooks are the most reliable evidence about its state and tool
calls. The engineering invariants already rank "full official lifecycle
reports" first. telar does not depend on hooks: the proxy and the screen keep
working when none are installed, and a lifecycle report expires like every
other evidence so a silent hook hands control back.

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
parse the harness payload once
        |
        +-> lifecycle mapping -> schema.report_agent
        |                         -> routeReportAgent -> ReportAgentHandler
        |                         -> Tracker.observeReport -> Agent.applyReport
        |
        +-> manifest command_tools mapping -> schema.report_agent_command
                                          -> ReportAgentCommandHandler
                                          -> history.Service.recordAgentCommand
        |
reproject lifecycle state; persist a running or completed agent command
```

The hook keeps the parsed JSON arena alive until both requests have been sent.
A lifecycle request updates the agent projection and session reference. A
command request runs only for a configured shell-tool mapping. `PreToolUse`
opens a `running` history row keyed by the tool call id; `PostToolUse` updates
that row in place. A finish without an open row inserts a completed row.

## Mapping

| Claude Code event | Report |
| --- | --- |
| `SessionStart` | `ready` + session reference |
| `UserPromptSubmit` | `working` |
| `PreToolUse`, `PostToolUse` | `working`; a mapped `Bash` call is also recorded |
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
| `PreToolUse`, `PostToolUse` | `working`; a mapped shell call is also recorded |
| `Stop` | `working`; a confirmed input prompt closes the turn |
| `Interrupt` | `ready` |
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
{ event, session_id, ...event data }  --stdin-->  telar hook pi
        |
hook lifecycle and manifest command mappings
        |
schema.report_agent or schema.report_agent_command
```

| Pi event | Report |
| --- | --- |
| `session_start` | `ready` + session reference |
| `agent_start` | `working` |
| `agent_settled` | `ready` (projected as `done` until seen) |
| `ui_prompt_start` | `blocked` |
| `ui_prompt_end` | `ready` when Pi was idle, else `working` |
| `tool_execution_start` | mapped shell tool opens a running command row |
| `tool_execution_end` | matching command row is completed |
| `session_shutdown` | `exited` |

Pi renders no permission prompts of its own, so `blocked` only comes from
extension dialogs, which is exactly what `ui_prompt_start` reports. The
session reference is Pi's UUIDv7 session id, which `pi --session <id>`
resolves for restore. Uninstall deletes the file only when it starts with
the Telar marker line, so a user's own extension at that path is never
touched.

## Ownership

`telar hook` never fails loudly: outside a pane, with a malformed payload or
an unreachable runtime it exits 0, so the agent is unaffected. It sends at
most one bounded lifecycle request and one bounded command request, then exits.

The runtime keeps the report as `Agent.report`, the first evidence
`chooseEvidence` consults while it is valid. A `working` report expires with
`working_expiry_ms`, other states with `settled_expiry_ms`; `applyProcess`
clears it when a different process takes the pane. Sounds follow the same
transition rule as screen evidence.

Codex runs every matching `Stop` hook before it decides whether another hook
will continue the turn. A `Stop` report therefore keeps the agent `working`.
A newer, explicit Codex input prompt withdraws that report and projects
`done`; a continuation produces no prompt and no premature notification.

The command field is data, not harness-specific branching. Built-in manifests
map Claude Code `Bash.command`, current Codex `Bash.command`, compatibility
names `exec_command.cmd` and `shell.command`, and Pi `bash.command`. A custom
manifest can declare the same mapping with `command_tools`. Subagent tool calls
are ignored. Native hook records use `origin = hook`; a later plugin record with
the same session and tool call id cannot duplicate it.

Claude Code reports a successful `PostToolUse`, so Telar closes it with exit
code zero. Failures use Claude Code's separate `PostToolUseFailure` event,
which Telar does not install. Codex's `PostToolUse` payload does not carry a
reliable process exit code, so its completed row keeps that field empty. Pi
reports `isError`; its extension maps that boolean to zero or one.

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
- `src/cli/hook.zig` proves the event mapping and subagent filtering for
  Claude Code, Codex and Pi; installed payload shapes; manifest-based shell
  extraction; and the parsed arena lifetime that backs both requests.
- `src/cli/integration.zig` proves idempotent install and selective removal
  for Claude Code, and rendering, marker detection and atomic owner-only
  installation for the Pi extension.
- `src/backend/history/persistence/sqlite.zig` proves that native start/finish
  updates one row and a later plugin observation with the same tool call id is
  deduplicated.
- `src/core/schema_contract_test.zig` pins the `report_agent` and
  `report_agent_command` bytes.
