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
        hooks.<owned event> += { type = command, command = "<pane guard>; exec '<telar>' hook <agent>", timeout = bounded }

Claude Code or Codex fires a hook (sh -c)
        |
[ -n "$TELAR_PANE_ID" ] && [ -n "$TELAR_PANE_GENERATION" ] || exit 0
        |   outside a telar pane the telar executable never runs
        |
telar hook <agent>   (stdin JSON; TELAR_PANE_ID + TELAR_PANE_GENERATION from the env)
        |
parse the harness payload once
        |
        +-> lifecycle mapping -> schema.report_agent
        |                         -> routeReportAgent -> ReportAgentHandler
        |                         -> Tracker.observeReport -> Agent.applyReport
        |
        +-> session name mapping -> schema.report_agent_title
        |                         -> routeReportAgentTitle -> ReportAgentTitleHandler
        |                         -> Tracker.reportTitle -> Agent.reportTitle
        |
        +-> manifest command_tools mapping -> schema.report_agent_command
                                          -> ReportAgentCommandHandler
                                          -> history.Service.recordAgentCommand
        |
reproject lifecycle state; persist a running or completed agent command
```

The hook attaches to a runtime that is already listening and never starts
one (`control.Session.attach`). The pane environment outlives the runtime
that injected it, so an orphaned agent must not resurrect a stopped runtime
from its hooks. Without a runtime the hook exits 0 and reports nothing.

The hook keeps the parsed JSON arena alive until both requests have been sent.
A lifecycle request updates the agent projection and session reference. A
title request carries the name the user gave the session inside the agent
(`/name`, `/rename`); it becomes the sidebar title with source `agent`,
outranks a generated title, is checkpointed like a manual one, and an empty
title clears it back to the placeholder. The agent never clears a manual
title. A command request runs only for a configured shell-tool mapping. `PreToolUse`
opens a `running` history row keyed by the tool call id; `PostToolUse` updates
that row in place. A finish without an open row inserts a completed row.

## Mapping

| Claude Code event | Report |
| --- | --- |
| `SessionStart` | `ready` + session reference; `session_title`, when present, as title |
| any event | `transcript_path` rides along as the session file so the runtime can watch it for `/rename` |
| `UserPromptSubmit` | `working` |
| `PreToolUse`, `PostToolUse` | `working`; a mapped `Bash` call is also recorded |
| `Stop` | `ready` (projected as `done` until seen) |
| `Notification` `permission_prompt`, `elicitation_*`, `agent_needs_input` | `blocked` |
| `Notification` `idle_prompt` | `ready` |
| `SessionEnd` | `exited`: the report is withdrawn, weaker evidence decides |
| any event with `agent_id` (subagent) | ignored |

| Codex event | Report |
| --- | --- |
| any event | the newest `state_<n>.sqlite` under `CODEX_HOME` rides along so the runtime can watch `threads.name` for `/rename` |
| `SessionStart` | `ready` + session reference |
| `SessionStart` with source `compact` | `working` + session reference |
| `UserPromptSubmit` | `working` |
| `PermissionRequest` | `blocked` |
| `PreToolUse`, `PostToolUse` | `working`; a mapped shell call is also recorded |
| `Stop` | `settling`, projected as `working` until a newer idle composer confirms completion |
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
| `session_start` | current idle/working state + session reference; the session name, when set, as title |
| `session_info_changed` | the new session name as title; a cleared name as an empty title |
| `agent_start` | `working` |
| `agent_settled` | current idle/working state (`ready` projects as `done` until seen) |
| `ui_prompt_start` | `blocked` |
| `ui_prompt_end` | `blocked` while another dialog remains, otherwise current idle/working state |
| `state_snapshot` | renews current idle/working/blocked state every 30 seconds while active |
| `tool_execution_start` | mapped shell tool opens a running command row |
| `tool_execution_end` | matching command row is completed |
| `session_shutdown` | `exited` |

Pi delivery is serialized through one child at a time, with a two-second child
limit and 32 pending payloads of at most 64 KiB each. Saturation drops the oldest
pending observation; renewal repairs missed state. There is no idle timer:
settlement and shutdown cancel it. Long runs and nested extension dialogs renew
their reports before expiry. Reinstall the extension after updating Telar and
reload it in Pi to activate changes in already running sessions.

A foreground Pi or Codex process establishes identity, not readiness. A model
response may precede local tools or another model request. Without fresh agent
completion evidence, expired work becomes `unknown`, never a completion sound.

Pi is the only agent whose rename reaches its hooks: `/name` fires
`session_info_changed`. Claude Code's `/rename` fires no hook and Codex has no
hook for its `/rename` either; their hooks report the file the session lives
in and [agent rename](agent-rename.md) covers how the runtime reads it.

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
`chooseEvidence` consults while it is valid. A `working` or `settling` report expires with
`working_expiry_ms`, other states with `settled_expiry_ms`; `applyProcess`
clears it when a different process takes the pane. Sounds follow the same
transition rule as screen evidence.

Codex runs matching `Stop` hooks before deciding whether a hook continues the
turn. `settling` preserves this distinction from active tool work while still
projecting `working`. A newer idle composer can settle `Stop`, but cannot
settle an unexpired `UserPromptSubmit`, `PreToolUse`, or `PostToolUse` report.
A continuation replaces pending settlement with active work.

Screen observation retains the PTY read's wall and monotonic timestamps across
worker delivery. Monotonic order distinguishes a final frame from a preceding
Stop even within one millisecond. An older screen cannot cancel a newer report.
The observer reconsiders unchanged Codex ready screens on actual output,
because the previous sample may have been rejected before Stop arrived.
Input or resize alone cannot renew screen evidence.

`history.codex_screen` scans at most 32 bottom rows with a fixed 1024-byte row
buffer. It anchors readiness to the live `›` composer and its cursor, accepts
drafts, and checks structured status clocks above the composer. A completion
separator excludes transcript quotes. An absent or obscured composer provides
no readiness proof. Incomplete VT sequences and synchronized frames provide
no observation until parsing completes. If output never completes, evidence
expires; observation never blocks PTY traffic or polls idle panes. After queue
loss, a partial composer cannot prove readiness until a fresh working status
reestablishes the screen observation.

For Codex, process presence and model-response completion cannot announce a
finished agent turn. Starting work discards previous ready-screen evidence;
expiry without fresh proof falls back to unknown rather than notifying done.
Claude retains its lifecycle mappings and screen detection policy. Pi uses
its ordered, renewed lifecycle reports as described above.

The current schema includes the `settling` report. Client, runtime, and hook
executable must use the matching schema; older peers are rejected at handshake.

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
adds an entry once per event, rewrites a telar entry whose command is stale
(an older unguarded form or another executable path), removes only entries
whose command ends in ` hook claude` or ` hook codex`, and rewrites the file
atomically with
two-space indentation. Other settings and hooks are untouched. Codex uses
`$CODEX_HOME/hooks.json` when `CODEX_HOME` is set and `~/.codex/hooks.json`
otherwise. Codex asks the user to trust the new hook definitions; telar does
not write Codex's trust state or bypass that check. Claude hooks use a
five-second timeout. Codex hooks use three seconds, the maximum Codex accepts
for `SessionEnd` and `Interrupt`.

## Proof

- `src/backend/agent/tracker.zig` proves precedence over screen evidence,
  `exited` withdrawal and expiry.
- `src/backend/runtime/entrypoints/requests/report_agent.zig` and
  `report_agent_title.zig` prove the reply contracts.
- `src/backend/agent/tracker.zig` proves that an agent title outranks a
  generated one, never clears a manual one, clears on an empty report and is
  durable.
- `src/cli/hook.zig` proves the event mapping and subagent filtering for
  Claude Code, Codex and Pi; installed payload shapes; manifest-based shell
  extraction; and the parsed arena lifetime that backs both requests.
- `src/cli/integration.zig` proves idempotent install and selective removal
  for Claude Code, and rendering, marker detection and atomic owner-only
  installation for the Pi extension.
- `src/backend/history/persistence/sqlite.zig` proves that native start/finish
  updates one row and a later plugin observation with the same tool call id is
  deduplicated.
- `src/core/schema_contract_test.zig` pins the `report_agent`,
  `report_agent_command` and `report_agent_title` bytes.
