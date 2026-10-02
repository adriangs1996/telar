# Worktrees and agent coordination

Status: implemented (W1–W8), with the deviations listed in
[Implementation](#implementation). The flows are
[worktree lifecycle](../flows/worktree-lifecycle.md),
[worktree detection](../flows/worktree-detection.md),
[worktree git probe](../flows/worktree-git.md),
[task cards](../flows/task-cards.md), [agent peek](../flows/agent-peek.md) and
[agent control](../flows/agent-control.md).

Implementation must follow the [invariants](../invariants.md) and the
[architecture](../architecture.md). New terms go to
[CONTEXT.md](../../CONTEXT.md) before they appear in code.

## Problem

A user works in one directory. An agent moves into a git worktree, finishes,
and leaves work to review somewhere else. telar keeps showing the workspace
the pane was launched in: `AgentCard.zig:58-72` prints the workspace's branch,
not the agent's. The user has to find the path, `cd` into it and remember
where each agent is.

The goal is control over what runs where, without `cd` and without paths on
screen:

- telar owns the lifecycle of every worktree it can see, whoever asked for it.
- Every worktree hangs from the workspace it came from and is named by its
  branch.
- Arbitrary commands run in a worktree through telar, agents included.
- One agent can coordinate others running in worktrees, through telar.

## Decisions

These were settled in the design discussion.

1. **telar manages worktrees; agents do not.** Agents call `telar worktree`
   through a skill. Claude Code's own worktree creation is routed through
   the same procedure by its `WorktreeCreate` hook.
2. **One location for every managed worktree:** telar's path template, today
   `<repo parent>/<repo>-worktrees/<branch>`, including worktrees adopted
   from Claude Code. `.claude/worktrees/` is not used.
3. **`exec` runs any argv.** Agents are not a special case: the runtime
   already detects agents by process (`Evidence.fromProcess`), and a prompt is
   an argument (`-- claude "fix X"`).
4. **A worktree is a location with its own tabs**, nested under its source
   workspace. Its tabs never appear in the source workspace's tab strip.
5. **telar never sends text to a pane that an attached client has focused.**
   That pane is where the user is typing.
6. **The coordinator pattern is the supported topology.** One agent delegates
   to agents in worktrees and collects their answers. Peer-to-peer messaging
   is possible but not designed for.
7. **An agent in a worktree is drawn as a task card**, grouped by project:
   the coordinator on top, its tasks hanging below. Cards are one line while
   work progresses and expand when they need attention.
8. **The project row shows only a worktree summary** (`⎇ N · ◌ n ✓ n`).
   Task cards are the way into a worktree; there are no worktree child rows.
9. **The peek offers direct controls** (open, diff, message, interrupt)
   through the same commands the coordinator uses.
10. **`--title` is required when `create` runs a command.** Without one (an
    external worktree), the title falls back to the agent's session title,
    then to the branch.

## Prior art

Checked on 2026-09-26 against source and docs.

| Tool | Who creates the worktree | How it is shown | Review |
| --- | --- | --- | --- |
| herdr | herdr (`herdr worktree create`); also detects linked worktrees from the pane cwd (`git_dir != common_dir`) | Indented child row under the repo, labelled with the checkout directory name; children suppress branch tokens | None; delegated to an agent |
| cmux | Nobody; the agent picks the topology | Branch, PR and ports per cwd; each worktree becomes its own project | Diff viewer, line comments sent to the agent |
| workmux | workmux; worktree = tmux window | `project/handle` plus agent status icon | WIP diff and `main...HEAD` diff, hunk comments to the agent, merge cleans up |
| worktrunk | worktrunk; intercepts Claude Code's `WorktreeCreate`/`WorktreeRemove` hooks | Table that drops the path column first | Picker with merge-base diff |

Common ground: names come from the branch, never the path; worktrees group
under their repository; agent state is the primary badge; review has two
scopes (uncommitted, and branch against merge-base); removing the checkout and
deleting the branch are separate decisions.

## Terms

Now in `CONTEXT.md`:

- **Worktree**: a git linked worktree that telar tracks as a location. It
  belongs to one project (by common directory) and hangs from one source
  workspace.
- **Source workspace**: the workspace a worktree hangs from in the UI.
- **Worktree handle**: the branch name shown for a worktree, with known tool
  prefixes removed (`worktree-` from Claude Code).
- **Worktree origin**: `telar` (created through `telar worktree`, including
  adopted hook calls) or `external` (found by observation).
- **Coordinator**: an agent that delegates work to agents in worktrees and
  collects their answers through `telar agent`.
- **Task**: the work delegated to one worktree, named by its title. It is
  what the user and the coordinator refer to ("the tabs one").
- **Task card**: the sidebar card of an agent that works in a worktree.
- **Peek**: an overlay that shows a task without changing tab or focus.

## Runtime model

Kill the TUI and ask what is lost. The worktree, its tabs, which agent works
in it and who sent it work are runtime state. Which worktree the user is
looking at, which rows are expanded and the accent color are client state.

### `Worktrees` table

One row per tracked worktree, owned by `RuntimeModel`.

| Column | Meaning |
| --- | --- |
| `id` | `WorktreeId`, already in `core/schema/id.zig` |
| `project` | common directory of the repository |
| `path` | checkout directory |
| `branch` | bounded like `Workspaces.git_branch` |
| `origin` | `telar` or `external` |
| `source_workspace` | `WorkspaceId` it hangs from |
| `created_by` | `PaneId` that ran `telar worktree create`, if any |
| `state` | `active`, `integrated` or `gone` |
| `git_dirty`, `git_checked_at_ms` | reuse the `workspace_git` probe |
| `title` | task title from `--title`, bounded |
| `brief` | the initial prompt, bounded; lets the coordinator match a task |
| `diff_added`, `diff_removed`, `diff_files`, `commits_ahead`, `diff_checked_at_ms` | diffstat against the merge-base plus uncommitted changes |
| `last_command` | program, status and exit code of the last `exec` |

`WorkspaceLocation.worktree` becomes a live location. Its tabs use the same
tab model as workspaces, as the existing doc comment in
`core/schema/types.zig` already states. Every consumer that treats `.worktree`
as null or unreachable today (`Workspaces.zig:317`, `TabRemoved.zig`,
`top_bar.zig:296-314`, `AgentCard.zig:68`, `SidebarState.zig:52`,
`WorkspaceIndicators.zig`, `agent_navigation.zig:31`) gets a real branch.

### Agent work tree

The `agents` table gains `work_tree: ?WorktreeId`, `final_message` (bounded),
and `plan_done`, `plan_total`, `plan_step` (one line) for task progress. It comes from the `cwd`
field of Claude Code hooks, which is an official report and outranks process
evidence. Today `ClaudeHookInput.cwd` reaches only command reports; the
lifecycle report (`hook.zig` `reportAgent`) needs to carry it.

The hook mapping also covers `PostToolUse` for `EnterWorktree` and
`ExitWorktree`, and `CwdChanged`, so the change is seen when it happens and not
at the next tool call.

### Resolving a directory to a worktree

Reading files is enough; no git subprocess:

1. Walk up from the directory to the first `.git` entry.
2. A directory means a main checkout: the common directory is that `.git`.
3. A file holds `gitdir: <path>`. That gitdir contains `commondir`, a path
   relative to the gitdir. `git_dir != common_dir` means a linked worktree.

`lib/gitstatus/probe.zig` already follows the gitfile; this extends it. It runs
in the observation worker on the maintenance tick, never in a request, render
or input handler (invariants, Agents).

### Persistence

A `WorktreeRecord` next to `WorkspaceRecord`: id, project, path, branch,
origin, source workspace. Following the local authority invariant, it never
stores argv. Commands started with `exec` are not relaunched after a runtime
restart; agents come back through their session references like any other
agent.

## CLI

```
telar worktree create BRANCH [--title TEXT] [--from REF] [--workspace ID|PATH] [--json] [-- ARGV...]
telar worktree exec BRANCH [--json] -- ARGV...
telar worktree list [--workspace ID|PATH] [--json]
telar worktree open BRANCH
telar worktree diff BRANCH [--uncommitted]
telar worktree remove BRANCH [--force] [--delete-branch]
telar agent interrupt TARGET
telar agent prompt TARGET [--interrupt] [--wait] [--json] TEXT
```

- The verb goes before the branch, as everywhere else in the CLI. A branch
  named `list` must not collide with a subcommand.
- `--` separates telar options from the command. The command travels as argv
  in `Launch.arguments`; it never goes through `sh -c`.
- `create` fails if the worktree exists; `exec` fails if it does not. A typo
  in a branch name must not create a worktree.
- `create` without a command opens one tab with the user's shell.
- `exec` opens a new tab in the worktree location for each call.
- `--workspace` targets another project, so a coordinator can reach the
  whole fleet from one pane. The runtime is one per account and already sees
  every workspace.
- `--json` prints `{id, path, branch, tab, pane}` for agents.
- `--title` is required when a command follows `--`. The skill always
  passes it.
- `worktree list --json` returns, per worktree: title, brief, branch, agent
  status, blocked reason, plan step, diffstat, last command and final
  message. The coordinator matches the user's words against it; telar does
  no matching of its own.
- `agent interrupt` sends the provider's interrupt keys, declared in its
  manifest. Today the manifest only detects the phrase `esc to interrupt`
  (`src/core/agent_manifest.zig:90`); it has no interrupt key. The command
  acts only while the agent is `working`.
- `agent prompt --interrupt` interrupts, waits for `ready`, then sends.
- Git runs in the CLI process with the user's environment, as decided in
  herdr-adoption P10. The runtime never runs git on behalf of a client.
- `telar workspace create --worktree` becomes an alias of `telar worktree
  create` and stops creating a top-level workspace.

## Creation paths

Three entries, one procedure:

1. **User or skill**: `telar worktree create`.
2. **Claude Code's own worktrees** (`--worktree`, `EnterWorktree`,
   `isolation: worktree`): a `WorktreeCreate` hook runs `telar hook claude`,
   which calls the same procedure and prints the path. Claude Code's docs
   state that this hook replaces its default `git worktree` logic and that
   the session's cwd becomes the returned path. `WorktreeRemove` maps to
   `telar worktree remove` without `--force`.
3. **Anything else** (a manual `git worktree add`, an agent ignoring the
   skill): observation of pane and agent working directories finds a linked
   worktree and records it with origin `external`, under the workspace of
   the same project, or the pane's workspace if there is none.

Claude Code asks for permission to enter a worktree outside
`.claude/worktrees/`. worktrunk answers this with a `PermissionRequest` hook
that approves paths matching its template; telar can do the same for paths it
created.

`telar integration` installs the hooks and the skill for each supported
agent. Agents without skills get the same instructions through `AGENTS.md`.

## Presentation

### Sidebar

The mockup is `.lavish/worktree-agent-cards.html` (local, not committed).

```
agentes · 6                      1 te necesita
▾ telar                                  ⎇ main ●
  C coordinador               ◌ trabajando 12s
  Rediseño del sidebar y links
  » telar worktree diff fix-tabs --stat
  │ Migrar history a SQLite v2        ⚠ permiso
  │ Bash: rm -rf .zig-cache/history
  │ ⎇ history-v2  +210 −95 · 11
  │ Links a ficheros con línea        ✓ revisar
  │ "Implementado con tests. Falta la doc."
  │ ⎇ path-links  +120 −30 · 6  ✓ test
  │ ◌ Ordenar tabs por uso   ⎇ fix-tabs    4m
  │ ✕ Arreglar flaky en pty_test   ⎇ pty-flaky
▸ guruwalk-api                  ⎇2 · ◌1 ✓1
```

- Agents are grouped by project. Agents in the main checkout draw the
  existing card; the coordinator carries a `coordinador` mark. Agents in
  worktrees of that project hang below as task cards, whoever created the
  worktree.
- The project name and favicon leave the task card; the group already says
  them.
- A task card has three rows:
  1. task title and status with age;
  2. what is happening: the plan step with a progress bar while working (or
     `last_event` when there is no plan), what it asks for while blocked, the
     first line of the final message when done;
  3. branch handle, diffstat, last `exec` result and provider mark.
- Density: a working task is one line (status, title, branch, age). Blocked,
  failed and done-but-unreviewed tasks are full cards and move to the top of
  the group. Hover or selection expands any card. Reviewed or integrated
  tasks are dimmed single lines.
- The project row shows only `⎇ N · ◌ n ✓ n`; a collapsed group shows the
  same summary.

### Peek

A click or `space` on a task card opens an overlay over the workbench:

- header: title, status, branch, base and commits ahead, provider, path in
  small mono (the only place a path appears);
- plan with the current step;
- the last rows of the pane, through the existing `read_pane`;
- changed files with per-file counts;
- actions: open (`↵`), diff (`d`), message (`m`), interrupt (`esc`).

`esc` with no action closes it. The actions call the same commands as the
coordinator, so the focus rule and the provider interrupt keys apply the
same way. Which card is expanded and whether the peek is open is client
state.

### Tab strip

Only the tabs of the current location. Inside `telar` the user sees their own
tabs plus a compact `⎇ 2` indicator; inside `fix-tabs`, only that worktree's
tabs. Launching three worktrees never changes the source workspace's tab
strip.

### Top bar

Inside a worktree, the top bar reads `telar › ⎇ fix-tabs` in a distinct
accent, so a worktree tab is never mistaken for the main checkout. A binding
returns to the source workspace. The fullscreen pane breadcrumb (`cf7c293b`)
is a candidate to reuse; its fit is not checked yet.

### Attention

Agent cards and notifications show `telar › ⎇ fix-tabs` and jump to the
worktree tab. `agent_navigation.zig` needs a destination for `.worktree`.

## Agent messaging

`telar agent prompt|wait|read` and `telar pane send-keys` already exist:
bracketed paste plus Enter, refusal with `agent_blocked`, and history
authorship. This plan adds four things.

### Worktree targets

`worktree:BRANCH` resolves to the agent in that worktree location. More than
one candidate is an error that lists them. It extends
`control.Snapshot.resolve`, which already resolves pane id, title and
`--current`.

### Structured replies

`telar agent read` scrapes the agent's screen: it carries TUI noise, stops at
64 KiB and depends on how each agent draws. The `Stop` hook already parses
`last_assistant_message`, but `hook_event.line` keeps only its first line as
the event. The lifecycle report carries the full message, bounded, into the
agent row, and `telar agent prompt ... --wait --json` returns it. Agents
without a stop report fall back to `read`.

The message is untrusted text: it is stored bounded and escaped in JSON, and
the coordinator skill tells the agent to treat it as data.

### Sender

When the CLI runs inside a pane (`TELAR_PANE_ID`), `send_pane_text` carries
the sender pane. The runtime:

- prefixes the prompt with one line, `[telar: from ⎇ sidebar-v2, pane 12]`,
  so the receiving agent knows the user did not type it;
- records the sender in history next to the existing agent authorship;
- shows `← sidebar-v2` on the receiving row until its next status change.

`TELAR_PANE_ID` is not a security boundary: any process in any pane can set
it. The sender is for attribution and loop control, not authorization.

### Focus rule

The runtime refuses `send_pane_text`, in prompt and raw mode, to a pane that
is the focused pane of the active tab of any attached client. The error is
`pane_focused`, distinct from `agent_blocked`, so the coordinator skill can
retry later. With no client attached (lid closed), every pane accepts text.

The runtime receives each client's tab layout with its focused pane
(`ClientTabLayoutView`, retained in `ClientLayouts`). Whether that update is
sent on every focus change must be checked before relying on it.

### Loops

A coordinator that prompts a worker, and a worker that prompts back, can
burn tokens without end. The runtime limits prompts per sender and target
pair within a window, both configurable, and refuses the excess with
`prompt_rate_limited`. Replies travel through `--wait`, not through prompts
back to the coordinator, so the normal pattern never hits the limit.

### Coordinator skill

A bundled skill, printed by `telar --skill coordinator` and installed by
`telar integration`:

1. `telar worktree create BRANCH --json -- <agent> "<task>"` per task.
2. `telar agent wait worktree:BRANCH --until done --json` to collect the
   final message.
3. `telar agent prompt worktree:BRANCH "<follow-up>" --wait --json` for
   corrections.
4. Never `remove --force`, never `--delete-branch`. Those belong to the user.

The coordinator's own context is the bottleneck, so workers answer with
summaries, not screen dumps.

## Review and lifecycle

- `telar worktree diff` shows `merge-base...HEAD`; `--uncommitted` shows the
  working tree against `HEAD`. The client opens it through the existing
  editor opening path.
- `integrated`: the branch adds no changes to its base. The row dims.
- `gone`: the checkout no longer exists. The row offers to forget it.
- `remove` runs `git worktree remove` without `--force`. `--force` asks for
  interactive confirmation and fails without a terminal. `--delete-branch`
  is separate and also asks.
- Agents may create and exec. Forced removal and branch deletion are the
  user's.

## Budgets

All of this is observation-path work. Resolving directories, probing git and
storing agent messages happen in workers or on the maintenance tick. The
interactive path gains one comparison: whether a text target is focused.
Sidebar labels are computed in the runtime snapshot, like `cwd_label`, not at
render time.

## Phases

Each phase is done when its flow document exists under `docs/flows/`, its
tests exist and `zig build test` plus the perf gate pass.

```
W1 location + create/exec/list/open ──> W2 agent work tree ──> W3 task card ──> W6 progress ──> W7 peek
          │                                     │                   │
          │                                     └──> W4 control <───┘
          └──> W5 review + lifecycle                     │
                                                         └──> W8 Claude hook adoption
```

- **W1. Worktree location and task identity.** `Worktrees` table with
  `title` and `brief`, `WorktreeRecord`, live `WorkspaceLocation.worktree`,
  `telar worktree create|exec|list|open` with `--title` and `list --json`,
  the alias for `workspace create --worktree`, tab strip per location, top
  bar breadcrumb and return binding. Done when a coordinator can list tasks
  and find one by its title.
- **W2. Agent work tree.** `cwd` in lifecycle reports, `EnterWorktree`,
  `ExitWorktree` and `CwdChanged` mapping, directory resolution in the
  worker, `agents.work_tree`, `external` detection from pane cwd.
- **W3. Task card.** GUI and TUI, with data that exists after W2: status,
  event, blocked reason, branch handle, and the full final message stored in
  `agents.final_message`. Grouping by project, density rules, project
  summary. Done when three agents in worktrees are told apart without
  opening any.
- **W4. Control.** `worktree:` targets, focus rule, sender line and history,
  `agent interrupt` with manifest interrupt keys, `prompt --interrupt`,
  `--wait --json` with the final message, rate limit, coordinator skill.
  Done when every sentence of the control table in the mockup works end to
  end.
- **W5. Review and lifecycle.** `worktree diff`, `integrated` and `gone`,
  safe `remove`, attention navigation to worktree tabs.
- **W6. Progress.** Diffstat probe (while working and on `Stop`, at most
  every 5 s per worktree, 2 s timeout, one in flight; after two timeouts it
  waits for the next `Stop`), plan progress from the task tool, last
  `exec` result. Done when the bar and diffstat move while the agent works
  without touching the frame budget.
- **W7. Peek.** Overlay with plan, screen, changes and actions. Done when a
  task can be seen and interrupted without changing tab or focus.
- **W8. Claude Code adoption.** `WorktreeCreate`, `WorktreeRemove` and
  `PermissionRequest` hooks through `telar integration`.

## Implementation

What was built differs from the plan above in these points.

- **A worktree's tabs live in a child workspace**, an ordinary
  `WorkspaceLocation.workspace` bound to the `Worktrees` row, instead of a
  live `WorkspaceLocation.worktree`. Every tab, pane, layout, navigation and
  checkpoint path works unchanged, and no consumer of `.worktree` needed a
  new branch. The workspace list shows projects only; child workspaces reach
  the UI as worktree entries.
- **`exec --wait`** was added so a coordinator runs tests, linters and
  searches in a worktree and gets their output and exit code. Finished
  panes keep their last 16 KiB and exit code in the runtime's `ExitedPanes`
  ring, and `pane_text` carries `exit_code`.
- **Untracked worktrees** of the same repository appear in `worktree list`
  and are adopted on their first `exec` or `diff`.
- **Restart**: panes launched by `create`/`exec` follow the existing pane
  record policy. An agent with a session reference resumes; a pane without
  one relaunches its recorded arguments, so a worker whose provider reported
  no session runs its original prompt again.
- **Sender**: the sender line is sent, but not recorded in history, and the
  receiving card shows no `← sender` mark. The prompt budget is fixed at 8
  per 60 s per pair, not configurable. The CLI sends a sender only when it
  talks to the runtime whose pane it runs in.
- **Card density**: a task card expands when it needs attention or is the
  focused agent, not on hover.
- **Peek**: a right click on a card opens it; its field sends a message, and
  `/stop`, `/diff` or an empty field interrupt, open a diff tab or open the
  agent's tab. The diff tab runs the coordinator's `telar worktree diff`
  through the pane's `TELAR_BIN_PATH`, then a shell. The GUI shows the last
  16 rows of the pane; the TUI shows the field only. It shows no per-file
  changes.
- **External worktrees** are detected from a pane's directory as well as
  from agent hooks ([worktree detection](../flows/worktree-detection.md)),
  and hang from the pane's own project: the runtime does not know which
  workspace holds the same repository, so "the workspace of the same
  project" is not looked up. Detection from a pane links no agent; only an
  agent's own hook sets its work tree, so an agent without hooks in an
  external worktree keeps its ordinary card.
- **Base of an external worktree**: the first probe measures it against the
  branch its main checkout stands on and keeps that base, since nothing
  recorded one.
- **`gone` rows** are forgotten all at once from the command palette ("Forget
  gone worktrees"), since a gone worktree whose agent exited has no card to
  offer it on; `telar worktree remove` forgets one.
- **Branches** are bounded at 200 bytes from the CLI to the checkpoint, the
  same bound everywhere; a longer one is refused before Git runs, never cut.
- **References**: `exec`, `open`, `diff` and `remove` take a branch or a
  unique title. `open` does not adopt an untracked worktree; `exec` and
  `diff` do. `remove` refuses uncommitted changes only; commits ahead stay
  on the branch.
- **`leave-worktree`** returns to the source workspace, bound to `prefix+u` ("up" to the project; `b` is a common sidebar binding).
- **`PermissionRequest`** is not installed. The `claude --worktree` run
  worked in the returned path; whether an `EnterWorktree` mid-session asks
  for permission was not checked.
- **`telar integration install claude`** installs the worktree hooks and the
  coordinator skill at `<settings dir>/skills/telar-coordinator/SKILL.md`;
  `telar --skill coordinator` prints it for other agents.

## Findings

- **Focus rule**: clients report their layout with its focused pane on each
  focus change, and the runtime's `ClientLayouts` follows it. Verified with a
  TUI in a PTY: a prompt to its focused pane fails with `pane_focused`, to
  any other pane it succeeds.
- **`WorktreeCreate`** receives `name` and `cwd` and expects the absolute path
  on stdout; `WorktreeRemove` receives `worktree_path`. Verified with
  `claude --worktree`.
- **`CwdChanged`** (Claude Code 2.1.283, `claude -p` with a hook that saved
  its input) carries `old_cwd` and `new_cwd`, and its `cwd` still names the
  directory it left; the progress report reads `new_cwd`.
- **Claude Code's task tools** are `TaskCreate {subject, description,
  activeForm}` and `TaskUpdate {taskId, status}`, numbered from one in
  creation order. `TodoWrite` is still mapped.
- **Codex** reports `Stop` with `last_assistant_message`. The Codex build
  tested runs tools through `exec` and offered no `update_plan`, so its task
  cards show no plan bar.
- **Interrupt keys**: `escape` for Claude Code and Codex. Claude Code runs no
  `Stop` hook for an interrupted turn, so the runtime reports `ready` itself.
- **Two earlier defects surfaced under a fleet** and are fixed. The runtime
  published a pane's title and progress while the VT actor was ingesting
  it, so a debug runtime aborted in `Delivery.assertIdle` when an attached
  agent's spinner title changed mid-delivery; those lanes now wait like the
  cell lane. The TUI presented a model changed earlier in the same inbox
  turn before observing it, so a debug client aborted in
  `Presenter.presentDue` at startup; `presentNow` now leaves that frame to
  the turn's closing observation.
- **End to end**: a Claude Code coordinator in a TUI delegated to a Claude
  Code and a Codex worker through `worktree exec`, approved a worker's
  permission with `pane send-keys`, waited with `agent wait --until
  finished` and reported final answers and diffstats; the sidebar showed
  the task cards, densities and states throughout. The TUI was driven in
  tmux; the GUI with `tools/gui_fleet.py`, checked through accessibility
  records and effects because screen capture was not permitted.
- **Not verified**: whether Claude Code calls `chdir` on `EnterWorktree`
  (hook `cwd` resolves the worktree either way), how each agent handles a
  prompt that arrives mid-turn, and which agents besides Claude Code load
  skills.
