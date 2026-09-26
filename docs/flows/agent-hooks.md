# Agent hooks

An agent's own hooks are the most reliable evidence about its state and tool
calls. The engineering invariants already rank "full official lifecycle
reports" first. telar does not depend on hooks: the process and the screen
keep working when none are installed, and a lifecycle report expires like
every other evidence so a silent hook hands control back.

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
        |                         -> client_request.receive -> agent_hooks.receive
        |                         -> agent_status.observeReport -> Agent.applyReport
        |
        +-> session name mapping -> schema.report_agent_title
        |                         -> client_request.receive -> agent_hooks.receiveTitle
        |                         -> agent_status.reportTitle -> Agent.reportTitle
        |
        +-> manifest command_tools mapping -> schema.report_agent_command
                                          -> agent_hooks.receiveCommand
                                          -> Pane.recordAgentCommand
                                          -> history.Service.recordAgentCommand
        |
reproject lifecycle state; persist a running or completed agent command
```

The hook attaches to a runtime that is already listening and never starts
one (`Session.attach` in `src/cli/Session.zig`). The pane environment outlives the runtime
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
| `PreToolUse` of `AskUserQuestion` | `blocked`, reason `question`, event: the first question |
| `PreToolUse` of `ExitPlanMode` | `blocked`, reason `plan` |
| `PreToolUse`, `PostToolUse` | `working`, event `» <tool> <first known argument>`; a mapped `Bash` call is also recorded |
| `Stop` with a running subagent in `background_tasks` | `waiting`, event `waiting for <n> background agents` |
| `Stop` otherwise | `ready` (projected as `done` until seen), event: the first line of `last_assistant_message` |
| `Notification` `permission_prompt` | `blocked`, reason `permission`, event: the notification message |
| `Notification` `elicitation_*`, `agent_needs_input` | `blocked`, reason `question`, event: the notification message |
| `Notification` `idle_prompt` | `idle`: settles like `ready` unless an unexpired `waiting` report holds |
| `SessionEnd` | `exited`: the report is withdrawn, weaker evidence decides |
| `PreToolUse`, `PostToolUse` with `agent_id` (subagent) | `continuing`: renews an unexpired `working` report |
| any other event with `agent_id` (subagent) | ignored |

| Codex event | Report |
| --- | --- |
| any event | the newest `state_<n>.sqlite` under `CODEX_HOME` rides along so the runtime can watch `threads.name` for `/rename` |
| `SessionStart` | `ready` + session reference |
| `SessionStart` with source `compact` | `working` + session reference |
| `UserPromptSubmit` | `working` |
| `PermissionRequest` | `blocked`, reason `permission`, event `» <tool> <argument>` |
| `PreToolUse`, `PostToolUse` | `working`, event `» <tool> <argument>`; a mapped shell call is also recorded |
| `Stop` | `settling`, projected as `working` until a newer idle composer confirms completion |
| `Stop`, `Interrupt` with subagents running in the rollout | `waiting`, event `waiting for <n> background agents` |
| `Interrupt` | `ready` |
| `SessionEnd` | `exited`: the report is withdrawn, weaker evidence decides |
| `PreToolUse`, `PostToolUse` with `agent_id` (subagent) | `continuing`: renews an unexpired `working` or `waiting` report |
| `SubagentStop` of the session's last running child | `released`: settles an unexpired `waiting` report |
| any other event with `agent_id` (subagent) | ignored |

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
| `ui_prompt_start` | `blocked`, reason `question` |
| `ui_prompt_end` | `blocked` (reason `question`) while another dialog remains, otherwise current idle/working state |
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

## File change review

Claude Code `Write` and `Edit`, and Codex `apply_patch`, also record before/after
file evidence through `report_change_review_sample`. This works in ordinary
terminal panes using their inherited pane ID, generation and provider session.
It does not require launching the agent in Telar's agent mode.

Review reads expose the canonical provider session. Mutations carry that same
session as well as the pane generation and expected revision, so resuming a
different thread in the same pane cannot redirect a pending comment. CLI
callers can also pin reads and edits with `--session SESSION`.

The hook subprocess reads files before returning from `PreToolUse` and after
`PostToolUse`; the runtime receives bounded bytes rather than doing filesystem
work while handling input. Claude declares its path in `tool_input.file_path`.
Codex declares paths in the Add/Update/Delete/Move headers of
`tool_input.command`. Telar reads those headers to identify files; it does not
apply the patch or parse source languages. These shapes follow the
[Claude hook reference](https://code.claude.com/docs/en/hooks) and
[Codex hook reference](https://developers.openai.com/es-419/docs/hooks).

Each tool can declare at most 32 distinct paths, and each file sample is capped
at 24 KiB. Every path component rejects symlinks. Files must be regular UTF-8
text, with stable size and modification metadata during the read. Empty files
and absent files are distinct. Binary, oversized, inaccessible and unstable
files are omitted rather than truncated. Traversal components and malformed or
oversized path lists are rejected. An unmatched after sample supplies no base
from which Telar can claim a diff.

These editions are labeled `observed_snapshot`: they capture the transition
around the named tool, but another process might write the same file between
the snapshots. Telar does not use the working tree's Git diff to attribute
unrelated changes. Shell commands and unrecognized tools are not automatically
captured. Pi's current asynchronous extension delivery cannot guarantee a
before snapshot, so it does not advertise this capture capability.

Only explicitly submitted review feedback is sent to the agent. On the next
`PreToolUse`, `PostToolUse` or `UserPromptSubmit`, the hook fetches feedback for
its exact provider/session and emits official
`hookSpecificOutput.additionalContext` JSON. It acknowledges the feedback ID
after flushing stdout. This hands feedback to the provider; it is not evidence
that the model has acted on it. A lost acknowledgement or concurrent hooks can
repeat the same ID, so delivery has at-least-once semantics. Telar never types
review text into an ordinary pane's PTY and does not wake an idle agent with
an unsolicited turn.

Other cooperative integrations can use the same runtime API explicitly:

```sh
telar review feedback --current --provider codex --session SESSION --json
telar review ack --current --provider codex --session SESSION --feedback-id ID
```

The feedback read does not consume it; the adapter acknowledges only after
accepting it. `telar review list/show/comment/delete/submit/reviewed` provides
the inspection and review actions from the terminal. `comment` accepts
`--edition`, `--file`, `--first`, `--last`, `--body` and optional `--before`;
`--revision` makes the optimistic revision check explicit. Both the CLI and
hooks attach to an existing runtime and never start an orphaned one.

## Ownership

`telar hook` never fails loudly: outside a pane, with a malformed payload or
an unreachable runtime it exits 0, so the agent is unaffected. Lifecycle,
command and title reports remain bounded; supported file tools add at most
32 file samples, and cooperative feedback adds one read and acknowledgement.

The runtime keeps the report as `Agent.report`, the first evidence
`chooseEvidence` consults while it is valid. Its reason and event line are
shown on the agent card only while that report decides the projection; the
event is one control-free line of at most 96 bytes, cut by `telar hook`
before it is sent. A `working` report expires with
`report_working_expiry_ms`, ten minutes, because a long model turn fires no
hook in between, and so does a `waiting` report; a `settling` report with
`working_expiry_ms`, other states with `settled_expiry_ms`; `applyProcess`
clears it when a different process takes the pane. Sounds follow the same
transition rule as screen evidence.

Claude Code dispatches background agents and ends the turn while they run:
its `Stop` fires with them still listed in `background_tasks` as `running`
subagents. That field is absent from Claude Code's hook reference, so an
absent list keeps the plain `Stop` mapping. Running shells are not counted,
because a dev server outlives every turn. Such a `Stop` reports `waiting`,
projected as `working`. A finished background agent resumes the main thread
with a `UserPromptSubmit` and a new `Stop`, which settles the agent once no
subagent is left running.

Sixty seconds after any `Stop`, Claude Code sends the `idle_prompt`
notification, running subagents or not, and without `background_tasks`.
It maps to `idle`, which the runtime drops while an unexpired `waiting`
report holds and otherwise applies as `ready`. An Esc interrupt fires
neither `Stop` nor `idle_prompt` (observed with Claude Code 2.1.283), and
Claude's screen cannot settle a report, so an interrupted turn stays
`working` until its report expires.

A background agent can outlast `report_working_expiry_ms` without a main
thread hook. Its own tool calls report `continuing`, which renews an
unexpired `working` or `waiting` report once less than
`report_renewal_margin_ms` is left, so a burst of calls republishes the
projection once. `continuing`
never registers an agent, never replaces `blocked`, `ready` or `settling`,
and never revives an expired report; the screen then decides as before.

Codex fires the main thread's `Stop` while children that `spawn_agent`
started still run, sometimes before their `SubagentStart`, and lists them in
no payload. The session's rollout (`transcript_path`) does: one
`SubAgentActivity` item with `kind` `started` when a child is spawned, before
the `Stop`, and one with `kind` `completed` when it finishes, both keyed by
the child's thread id, which its hooks carry as `agent_id`. On `Stop`,
`Interrupt` and `SubagentStop`, `telar hook codex` streams that rollout
through a fixed window (`CodexSubagents.read`), a regular file the user owns,
and counts the children started without a completion. The finishing child is
left out, because its completion is written after its `SubagentStop` runs.
Codex resumes no turn for a finished child, so the last child's
`SubagentStop` reports `released`, which ends only a wait still in force and
leaves a newer turn alone. A nested child's `SubagentStop` names its parent's
rollout, not the session's, and is ignored.

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

The current schema includes the `settling`, `continuing`, `waiting` and `idle` reports. Client, runtime, and hook
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

## Validation

- `src/backend/runtime/tests/agent_status_test.zig` proves precedence over screen evidence,
  `exited` withdrawal and expiry.
- `src/backend/runtime/agent_hooks.zig` holds the reply contracts for
  `report_agent`, `report_agent_command` and `report_agent_title`.
- `src/backend/runtime/tests/agent_status_test.zig` proves that an agent title outranks a
  generated one, never clears a manual one, clears on an empty report and is
  durable.
- `src/cli/hook.zig` proves the event mapping and subagent filtering for
  Claude Code, Codex and Pi; installed payload shapes; manifest-based shell
  extraction; and the parsed arena lifetime that backs both requests.
- `src/cli/integration_support.zig` proves idempotent install and selective removal
  for Claude Code, and rendering, marker detection and atomic owner-only
  installation for the Pi extension.
- `src/backend/history/persistence/history_sql.zig` proves that native start/finish
  updates one row and a later plugin observation with the same tool call id is
  deduplicated.
- `src/core/schema_contract_test.zig` pins the `report_agent`,
  `report_agent_command` and `report_agent_title` bytes.
