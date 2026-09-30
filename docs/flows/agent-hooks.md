# Agent hooks

An agent's own hooks are the most reliable evidence about its state and tool
calls. The engineering invariants already rank "full official lifecycle
reports" first. telar does not depend on hooks: the process and the screen
keep working when none are installed, and a lifecycle report expires like
every other evidence so a silent hook hands control back.

## End-to-end path

```text
telar integration install claude|codex|cursor
        |
~/.claude/settings.json, ~/.codex/hooks.json or ~/.cursor/hooks.json
        hooks.<owned event> += { type = command, command = "<pane guard>; exec '<telar>' hook <agent>", timeout = bounded }
        (Cursor lists { command, timeout } directly under the event, beside version: 1)

Claude Code, Codex or Cursor Agent fires a hook (sh -c)
        |
[ -n "$TELAR_PANE_ID" ] && [ -n "$TELAR_PANE_GENERATION" ] || exit 0
        |   outside a telar pane the telar executable never runs
        |
telar hook <agent>   (stdin JSON; TELAR_PANE_ID + TELAR_PANE_GENERATION from the env)
        |
parse the harness payload once
        |
schema.verify_pane_descent -> agent_hooks.receiveDescent
        -> peer process from the socket -> observation worker walks its parents
        -> agent_hooks.finishDescent: the pane's root process is among them?
        |   yes: the connection is bound to the pane (Session.hook_pane)
        |   no: exit 0, report nothing (a process that left the pane)
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

Every report names the agent whose hook sent it (`provider` on
`report_agent`, `report_agent_title` and `report_agent_progress`, the
manifest name on `report_agent_command`), and `agent_status.acceptsReporter`
refuses one for a pane that runs another agent with `foreign_process`; see
[pane identity](#pane-identity).

The hook keeps the parsed JSON arena alive until both requests have been sent.
A lifecycle request updates the agent projection and session reference. A
title request carries the name the user gave the session inside the agent
(`/name`, `/rename`); it becomes the sidebar title with source `agent`,
outranks a generated title, is checkpointed like a manual one, and an empty
title clears it back to the placeholder. The agent never clears a manual
title. A command request runs only for a configured shell-tool mapping. `PreToolUse`
opens a `running` history row keyed by the tool call id; `PostToolUse` updates
that row in place. A finish without an open row inserts a completed row.

## Pane identity

`TELAR_PANE_ID` names the pane a process was started in; it does not prove
the process still runs there. A process that leaves the pane keeps the
variable: a server started from the pane that detaches into a session of its
own, or anything it starts. Codex's CLI hands every session to one shared
`codex app-server --managed-daemon` unless it runs with `--no-daemon` (Codex
0.159). The daemon runs the hooks of every session it serves with the
environment it inherited from wherever it was started, so its reports once
named that pane for sessions running in others. Measured on 2026-09-30: the
daemon's parent was `launchd`, the Codex CLI in the pane held only a socket
to it, and the tools and MCP servers ran as the daemon's children.

Two checks keep a pane's card to its own agent:

1. **Descent.** Before any report, `telar hook` sends `verify_pane_descent`
   for the pane its environment names. The runtime asks the kernel for the
   process at the other end of the connection (`LOCAL_PEERPID` on macOS,
   `SO_PEERCRED` on Linux; the hook opens the connection itself and shares it
   with no one) and an observation worker walks that process's
   parents (`proclineage.ancestors`, at most 32 steps, `proc_pidinfo` or
   `/proc/<pid>/stat`, no allocation). Only when the pane generation's root
   process is the peer or one of its parents does the runtime bind that pane
   to the connection (`Session.hook_pane`) and complete the request; the
   hook reports nothing otherwise. A report that names its agent is accepted
   only on a connection bound to its pane, so a process cannot skip the
   check or vouch for itself. The request handler reads one socket option and
   starts the worker; one check runs per connection, and a closing
   connection waits for it.
2. **Agent.** A report names its agent. A pane whose process was last seen
   running another agent refuses it before any effect: lifecycle state,
   session, title, progress (and the external worktree a progress report
   registers) and command history. The refusal is `agent_mismatch`, and it
   asks the pane's next observation to identify the foreground process
   again even if its group did not change (`Cache.recheck`): the agent may
   have replaced the previous one without an exit the probe saw, by `exec`
   or by quitting and starting again between two probes. The hook retries
   the report up to four times, 250 ms apart, and the new agent's first
   drawing starts that observation, so its `SessionStart` state and title
   are kept. A process of another agent, such as `codex exec` run by Claude
   Code as a tool, is still refused after the check. A hook can fire before the runtime
   has identified the pane's process, as `SessionStart` can. Until then, the
   first agent that reports holds the pane (`Agent.reporter`). Process
   evidence of another agent then discards its report, session, session file
   watch, agent title and progress, and so does another agent taking a pane
   whose agent was already identified. A worktree registered or a command
   recorded in that window stays: it came from a process inside the pane.

A report that names no agent, as `telar agent report-state` and
`report-title` send, is the user's own and needs no descent. `telar agent`
reports and Claude Code's `WorktreeCreate` hook ask for descent too; outside
the pane, a report that names an agent (`report-command`) is refused. The
runtime also requires a connection confirmed inside the pane to attribute a
worktree to it (`register_worktree` with `created_by`; `telar worktree
create` registers without attribution when it cannot confirm), and to take
the pane's file evidence (`report_change_review_sample`) or hand its agent
review feedback (`feedback`, `ack_feedback`). These
checks separate agents, not users: same-user processes are not isolated from
each other (see [invariants](../invariants.md#local-authority)), and any of
them can start a process inside a pane.

A session reference also keeps the agent it belongs to, and a restore
resumes it only with that agent (`Agent.resumableSession`).

With the daemon, no process in the pane runs the hooks, so they reach no
card. Launch Codex with `--no-daemon` to keep its session in the pane, for
instance with a shell alias; `codex resume` and `codex fork` accept the flag
too, and `telar integration install codex` says so after installing. Telar
installs no wrapper: a directory Telar put first in the pane's `PATH` loses to
shell configuration that prepends its own, as `mise` and `pnpm` do.

The process probe reads Codex's arguments into a `SessionHost`
(`Capabilities.pane_session_argument` and `batch_arguments`): `pane` with
`--no-daemon`, `shared_server` for an interactive session without it (no
subcommand, `resume` or `fork`), `unknown` for a subcommand that runs no
interactive session, such as `exec`, `review`, `login` or `app-server`.
The card says `no hooks from this pane: if it runs on a shared server,
start it with --no-daemon` only when all of these hold: the session is
`shared_server`; telar's Codex hooks are installed (the observation worker
reads `$CODEX_HOME/hooks.json`, else `~/.codex/hooks.json`, for `hook
codex`, once per identified process, at most 32 KiB); the screen has shown
it working for five seconds; and no hook report of that process has
reached the pane. A turn's first hook arrives well within those seconds, so
a Codex older than the daemon, or one with the daemon turned off, never
shows the line. Without the integration the line never shows: there are no
hooks to miss. A restore resumes the way
the session ran: `codex resume --no-daemon <id>` only for a `pane` session,
since a Codex without the flag refuses it, and `codex resume <id>` otherwise.

The same check stops agents whose process is not a descendant of the pane's
root process, whatever runs them:

- an agent inside tmux, screen, zellij, dtach or abduco running in a telar
  pane: the multiplexer's server is its parent, and the server left the pane;
- one started with `setsid` or `nohup ... &` that outlived its shell and was
  adopted by `launchd` or `init`;
- one run through `ssh localhost` or `mosh`, whose remote shell descends from
  the SSH or mosh server, not from the pane;
- one in a container reached with `docker exec`, `podman exec` or a
  devcontainer, whose processes descend from the container runtime.

Their hooks reach no card, and the process and screen evidence of the pane
decide alone.

One case passes both checks: a shared server that stays a descendant of
any process in one pane, not only of its agent, and runs the hooks of an
agent of the same kind in another pane. Codex 0.159 detaches its daemon, so
it does not arise today.

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

## Cursor Agent

Cursor Agent's CLI runs the command hooks in `~/.cursor/hooks.json`. The
mapping below was captured with Cursor Agent 2026.08.11 and 2026.09.26 under
a pty, with a hook that recorded every payload.

| Cursor event | Report |
| --- | --- |
| any event | `conversation_id` is the session reference (`cursor-agent --resume <id>` restores it) |
| `sessionStart`, `beforeSubmitPrompt` | the chat's `meta.json` rides along so the runtime can watch its `title` for `/rename` |
| `sessionStart` | `ready` + session reference; fires when the TUI opens a new chat, never on `--resume` |
| `beforeSubmitPrompt` | `working`; the first hook of a resumed chat |
| `preToolUse`, `postToolUse`, `postToolUseFailure` | `working`, event `» <tool> <argument>`; a `Shell` call is also recorded, its exit code read from `tool_output` |
| `stop` | `ready`, whether `status` is `completed`, `aborted` or `error`; an Esc interrupt fires `aborted` then `error` |
| `sessionEnd` | `exited` |

No hook fires while a command waits for approval, and `beforeShellExecution`
runs before the approval dialog and for commands the allowlist already
permits, so it cannot say that the agent is blocked. The plan review ("Ready
to build?") follows the turn's `stop`, and the workspace trust dialog comes
before any hook. All three are screen evidence: the manifest matches "Not in
allowlist:", "Skip & tell the agent what to do instead", "Yes, build
locally" and "Do you trust the contents of this directory?", and
`screen_reports_blocked` lets a blocked screen observed after the latest
reported work decide the projection, with reason `other`.

Working and ready on screen come from `history.cursor_screen`, which reads
the live composer, the bottom row that starts with `→`. Traced frame by
frame on Cursor Agent 2026.09.26, a turn draws a braille spinner row
("⠀⠞ Working", "⠘⠣ Running  245 tokens") above the composer from its first
frame, and "ctrl+c to stop" joins the composer about 300 ms later; an idle
composer has neither. A spinner within six rows above the composer, or the
hint on it, reads `working`; the composer alone reads `ready`, confirmed.
A frame without the composer, such as one Cursor is still painting,
publishes nothing. Dialogs draw their options with the same arrow, so their
blocked phrases decide first. Without hooks this screen is the only
lifecycle evidence, and a finished turn settles as soon as the idle
composer is drawn; with hooks, the reports outrank it as for any agent. A
queue loss holds a ready composer back until a spinner is seen again, as
for Codex.

Cursor names its chat directory after the MD5 of the directory the agent
was launched from, `<config>/chats/<md5>/<conversation_id>/meta.json`, where
`<config>` is `CURSOR_CONFIG_DIR`, else `$XDG_CONFIG_HOME/cursor`, else
`~/.cursor`. Hooks carry the workspace root, not that directory, and the two
differ when the agent starts in a subdirectory. `telar hook cursor` therefore
tries the first workspace root, then visits at most 4096 launch directories
for the chat, and only on the events that open a session or a turn.

Cursor also imports Claude Code hooks from `~/.claude/settings.json` when its
third-party import is enabled. On the account used for these captures it was
not: Cursor's own hooks fired and Claude Code's did not.

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

Pi and OpenCode are the agents whose rename reaches Telar as an event: Pi's
`/name` fires `session_info_changed` and OpenCode's `/rename` publishes
`session.updated`. Claude Code's `/rename` fires no hook and Codex has no
hook for its `/rename` either; their hooks report the file the session lives
in and [agent rename](agent-rename.md) covers how the runtime reads it.

Pi renders no permission prompts of its own, so `blocked` only comes from
extension dialogs, which is exactly what `ui_prompt_start` reports. The
session reference is Pi's UUIDv7 session id, which `pi --session <id>`
resolves for restore. Uninstall deletes the file only when it starts with
the Telar marker line, so a user's own extension at that path is never
touched.

## OpenCode

OpenCode has no hook files either; a plugin receives its events. `telar
integration install opencode` writes `telar.ts` (bundled from
`src/cli/integration/opencode.ts`) into `plugins/` of OpenCode's global
configuration directory, `$XDG_CONFIG_HOME/opencode` or `~/.config/opencode`,
which OpenCode scans for `{plugin,plugins}/*.{ts,js}`
(`packages/opencode/src/config/plugin.ts`). A file plugin may export only
functions; OpenCode calls each export once per project directory it serves,
all inside the worker thread of the one `opencode` process, whose environment
is a copy of the TUI's (`packages/opencode/src/cli/cmd/tui.ts`). The plugin
therefore keeps the pane state at module scope and does nothing outside a
Telar pane.

```text
OpenCode plugin hook or bus event
        |
the plugin tracks the root session, whether it is busy and its open prompts
        |
{ event, session_id, busy, blocked, title | tool data }  --stdin-->  telar hook opencode
        |
hook lifecycle, title and manifest command mappings
        |
schema.report_agent, schema.report_agent_title or schema.report_agent_command
```

| OpenCode event | Report |
| --- | --- |
| plugin load (first instance) | `ready`: OpenCode publishes nothing before the first prompt, not even for a resumed session |
| `chat.message` hook | `working` + session reference |
| `session.status` `busy` or `retry` | `working`, once per change: OpenCode repeats `busy` several times a turn |
| `session.status` `idle` | `ready` (projects as `done` until seen), open prompts forgotten |
| `permission.asked` | `blocked`, reason `permission`, event `» <permission> <argument>` |
| `question.asked` | `blocked`, reason `question`, event: the first question; an open permission keeps deciding |
| `permission.replied`, `question.replied`, `question.rejected` | `blocked`, naming the prompt, while another prompt stays open (the newest permission, else the newest question), otherwise the busy state |
| `tool.execute.before` hook | `working`, event `» <tool> <argument>`, or nothing while a prompt is open; a mapped `bash` call opens a running command row |
| `tool.execute.after` hook | the matching command row is completed with `metadata.exit` |
| `session.updated` of the root session | its title, once per change; OpenCode's default title clears it |
| renewal | the current state every 30 seconds while busy or blocked, with the open prompt's request: the event line follows the latest report |
| `dispose` of the last instance | `exited`; the plugin forgets the turn and its prompts |

Captured on OpenCode 1.18.32 with a plugin that logged every event and hook
under an isolated configuration. A turn publishes `session.status` `busy`
several times and ends with `idle` followed by the deprecated `session.idle`,
which the plugin ignores. An interrupt (ESC twice) publishes `session.error`
with `MessageAbortedError`, then `idle`, and never replies to the prompt it
cancelled, so `idle` forgets every open prompt. `tool.execute.before` runs
before the permission is asked, so a command row opens while the user
decides; a rejected or aborted call never runs `tool.execute.after` or reports
`exit: null`, and its row keeps no exit code. The `permission.ask` hook is
declared in the plugin API but OpenCode never calls it, so `blocked` comes from
the `permission.asked` event. Subagents of the task tool run in child
sessions that carry a `parentID`: their status and tool calls are ignored,
while their permissions and questions block the pane under the root session.
`!` shell commands typed in the TUI bypass the tool hooks and carry no exit
code, so they are not recorded.

OpenCode runs the tool calls of one step on their own and each asks for its
permission inside the tool, after `tool.execute.before`
(`packages/opencode/src/session/tools.ts`, `permission/index.ts` in
v1.18.30). A call can therefore start while another call's permission is
open; the plugin sends the open prompt with it and the hook reports no state,
so the pane stays blocked with the prompt's event line. Measured on 1.18.32:
with `bash` set to ask, one step's `bash`, two `read` and two `glob` calls
ran the four others while the `bash` permission waited. The edit, write and
apply_patch tools ask as `edit` with the path in `metadata.filepath` and the
whole diff in `metadata.diff`, which has no bound. A payload past 64 KiB keeps
only the tool input's string fields up to 4096 characters and its first
question, so the prompt still reaches the runtime at once.

OpenCode's `dispose` hook runs for every instance before the process exits,
and OpenCode waits for it; the last instance reports `exited` and waits up to
2.5 seconds for the queue to drain. A reload disposes every instance too
(`SIGUSR2` to the TUI, a configuration change through the server), rejects
open prompts without replying, and loads the plugin again from the same
module in the same process (`cli/tui/worker.ts`, `plugin/index.ts`), so
`dispose` forgets the turn and its prompts and the new first instance reports
`ready` after the exit. Measured on 1.18.32 with `SIGUSR2`: an idle pane
reported `exited`, fell back to `unknown` and reported `ready` seven seconds
later; with a permission open, the turn ended with `session.status` `idle`,
one more `idle` arrived after `dispose`, and the pane settled on `ready`.
OpenCode's TUI kept drawing that permission, but it no longer answers: Enter
and Escape did nothing and the command never ran, so the pane does not report
it as blocked. Delivery is serialized like Pi's: one child at a time with a two-second limit and 32 pending payloads of at most
64 KiB, dropping the oldest. The session reference is OpenCode's
`ses_`-prefixed id, which `opencode --session <id>` resumes; OpenCode prints
that command when it exits. Uninstall deletes the file only when it starts
with `// telar-integration: opencode`. Reinstall after updating Telar and
restart OpenCode to load the new plugin.

## File change review

Claude Code `Write` and `Edit`, Codex `apply_patch`, and Cursor Agent `Write`
and `Delete` also record before/after file evidence through
`report_change_review_sample`. Cursor reports every edit, a search-and-replace
included, as a `Write` of the whole file. This works in ordinary
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
before snapshot, so it does not advertise this capture capability, and the
OpenCode plugin does not capture file changes yet.

Only explicitly submitted review feedback is sent to the agent, and only to
Claude Code and Codex: Cursor's tool hooks document no context field for it. On the next
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

`telar hook` never fails loudly: outside a pane, from a process that left it,
for a pane that runs another agent, with a malformed payload or an
unreachable runtime it exits 0, so the agent is unaffected. Lifecycle,
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
names `exec_command.cmd` and `shell.command`, Pi `bash.command`, Cursor
Agent `Shell.command` and OpenCode `bash.command`. A custom
manifest can declare the same mapping with `command_tools`. Subagent tool calls
are ignored. Native hook records use `origin = hook`; a later plugin record with
the same session and tool call id cannot duplicate it.

Claude Code reports a successful `PostToolUse`, so Telar closes it with exit
code zero. Failures use Claude Code's separate `PostToolUseFailure` event,
which Telar does not install. Codex's `PostToolUse` payload does not carry a
reliable process exit code, so its completed row keeps that field empty. Pi
reports `isError`; its extension maps that boolean to zero or one. Cursor
Agent nests `{"output":…,"exitCode":N}` in the string `tool_output` of a
`Shell` `postToolUse`; a `postToolUseFailure` closes the row without a code.
Cursor leaves a command's `cwd` empty when it runs in the workspace, so the
row records the first workspace root. OpenCode's `bash` reports its status in
`metadata.exit` of `tool.execute.after`, `null` when the command was aborted
or timed out; the row records `workdir` when the call names one and the
project directory otherwise.

`telar integration` edits only the event arrays owned by the selected agent,
adds an entry once per event, rewrites a telar entry whose command is stale
(an older unguarded form or another executable path), removes only entries
whose command ends in ` hook claude`, ` hook codex` or ` hook cursor`, and
rewrites the file
atomically with
two-space indentation. Other settings and hooks are untouched. Codex uses
`$CODEX_HOME/hooks.json` when `CODEX_HOME` is set and `~/.codex/hooks.json`
otherwise. Codex asks the user to trust the new hook definitions; telar does
not write Codex's trust state or bypass that check. Cursor always reads user hooks from `~/.cursor/hooks.json`, whatever
`CURSOR_CONFIG_DIR` says; install adds `"version": 1` when the file lacks it,
and Cursor's own JSONC comments make the file unreadable to install, which
then leaves it untouched. Claude and Cursor hooks use a
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
  Claude Code, Codex, Pi, Cursor Agent and OpenCode; installed payload shapes; manifest-based shell
  extraction; and the parsed arena lifetime that backs both requests.
- `src/cli/integration_support.zig` proves idempotent install and selective removal
  for Claude Code and Cursor Agent's flat layout, and rendering, marker detection and atomic owner-only
  installation for the Pi extension and the OpenCode plugin.
- `src/cli/integration/opencode.test.mjs` proves the plugin's ordered
  delivery, deduplicated busy reports, prompt tracking and renewal with the
  open prompt's request, tool calls under an open prompt, oversized prompts,
  interrupt settlement, reloads, subagent filtering, title and exit reports.
- `src/cli/integration/install.test.mjs` drives a built `telar integration`
  for Pi and OpenCode in a throwaway home: status, install, update,
  uninstall, a foreign file left untouched, and `--settings` paths.
- `zig build test-integrations`, part of `zig build test`, runs both with
  Node (22.13 or newer, for `module.stripTypeScriptTypes`) along with
  `pi.test.mjs`.
- `src/cli/integration/hook_identity.test.mjs` drives a built telar in a
  runtime of its own: two Codex sessions with `--no-daemon` in two panes of
  one directory report only to their own cards, a server started from one
  pane that leaves it reaches no card, each rename reaches only its own card
  and a restart resumes each session in its pane with `--no-daemon`; a Codex
  without the flag says so on its card, and one whose hooks reach its pane
  without it shows no line and resumes without the flag.
- `src/backend/runtime/tests/requests_test.zig` proves that a report naming
  an agent needs a connection bound to its pane and generation, that a
  connection confirmed in one pane cannot report for another, that another
  agent's report is refused with a recheck and accepted once the probe names
  that agent, that worktree attribution and review evidence need the
  confirmation too, one descent check per connection, and a descent check
  through the real peer lookup and worker; `agent_hooks.zig` proves the
  parent walk; `agent_status_test.zig` proves the identification window, a
  pane whose agent is replaced, the resume mode and when the shared-server
  line shows; `process.zig` proves `SessionHost` and the recheck;
  `hook_integration.zig` proves the installed-hooks check; `lib/proclineage`
  and `lib/localsocket` prove the parent chain and the peer process.
- `src/backend/runtime/tests/client_events_test.zig` proves that a client
  negotiates while another connection's handshake stalls, and that only a
  full admission table interrupts its oldest handshake.
- `src/cli/TempFile.zig` proves that installation writes through an
  exclusive owner-only temporary and never through a planted symlink.
- `src/backend/history/persistence/history_sql.zig` proves that native start/finish
  updates one row and a later plugin observation with the same tool call id is
  deduplicated.
- `src/core/schema_contract_test.zig` pins the `report_agent`,
  `report_agent_command`, `report_agent_title` and `verify_pane_descent`
  bytes.
