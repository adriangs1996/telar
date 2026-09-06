# Agent mode: threads beside the multiplexer

Baseline: telar `79f0506` (main), 2026-09-06. Research inputs: the telar
source tree, the local herdr checkout (0.7.5 docs and changelog), Adrian's own
agent session files on disk, and web research over terminal-native and
graphical agent managers. Every claim below is marked as verified in code or
docs, measured on this machine, or my own judgement.

Decisions taken in the 2026-09-06 review, in two rounds: the mode is called
**agent mode** and its unit a **thread** in code, config, wire and CLI
(`README.md` keeps hilo and trama as prose); opening a thread that lives in
another workspace performs the existing handoff in P0; transcripts are
indexed with previews and never copied; the quick prompt ships in P1; the
base layout is A (three columns, conversation as a view tab); the target
look after P0 is C (KGP chrome under cell text, D only as a later
experiment); the composer is a built-in multi-line widget; a new thread
lands as one tab per thread in the project's workspace. The second round
added one requirement: the interface is provider-independent, and the
composer lets the user pick the provider and configure its model, effort and
mode, the way T3 Code does. That is the "Provider independence and the
composer" section.

Status: closed on 2026-09-06 after six review rounds. Implement from this
document and the reference files below; the review page is kept only as a
visual record.

## Reference files

| File | What it is |
| --- | --- |
| `docs/plans/agent-mode.md` | This specification. The appendices at the end carry the keymap, wire messages, DDL, manifest schema, composer and KGP specifications, the invariants exception and the session-reader mapping. |
| `docs/plans/agent-mode/mocks/NN-*.txt` | Cell-exact mockups, one file per screen or state, padded to their width. Column positions are normative. |
| `docs/plans/agent-mode/mocks/NN-*.roles.txt` | The same mockups with every styled run tagged `«role:text»`; the role legend maps to `theme.Palette` in `mocks/README.md`. |
| `docs/plans/agent-mode/mocks/README.md` | Widths, roles, glyph set. |
| `docs/plans/agent-mode/review.html` | The self-contained review page: the KGP looks (hybrid composer, rasterized composer, hybrid conversation, canvas) are rendered there as HTML mockups, and the T3 Code facts are cited with file paths. Open it in a browser. |
| `docs/adr/0009-agent-mode-is-a-client-projection-of-one-runtime.md` | Why agent mode owns no runtime state and why provider knowledge lives in manifests and readers. |
| `docs/adr/0010-index-agent-transcripts-instead-of-copying-them.md` | Why transcripts are read from the agent's files and only indexed. |
| `docs/adr/0011-rasterize-the-composer-editor-behind-a-latency-gate.md` | Why the composer editor may cross the media path, and the gate. |
| `CONTEXT.md`, section "Threads and agent mode" | The vocabulary: project, thread, thread item, registry, blocked reason, the two modes, browse and interact focus, composer, provider option, live command. Code, docs and UI use these words. |
| `~/sandbox/t3code` (external, 2026-07-07) | T3 Code's composer, the reference for the composer's behavior: `apps/web/src/components/chat/ChatComposer.tsx`, `ProviderModelPicker.tsx`, `TraitsPicker.tsx`, `ComposerPrimaryActions.tsx`, `ChatView.logic.ts` (`deriveLockedProvider`). |

## Decision log

All taken by Adrian in the review of 2026-09-06.

| # | Decision |
| --- | --- |
| 1 | The mode is **agent mode** and the unit a **thread** in code, config, wire and CLI; hilo and trama stay README prose. Domain code lives under `threads/` namespaces because `thread` collides with `std.Thread` in grep. |
| 2 | Opening a thread whose pane lives in another workspace uses the existing handoff in P0. Attaching across workspaces is not planned. |
| 3 | Transcripts are indexed with 512-byte previews; text is read on demand from the agent's file; nothing is copied. |
| 4 | The quick prompt ships in P1, inside the composer. |
| 5 | Layout **A**: three columns, conversation as a view tab. B (cockpit) rejected. |
| 6 | Target look **C**: KGP chrome under cell text. D (canvas) only as a later experiment on the conversation view. |
| 7 | The composer is a built-in multi-line widget, not the name prompt. |
| 8 | A new thread lands as one tab per thread in the project's workspace. |
| 9 | Model and effort can change on a running thread from the composer through the manifest's live command, with a pending state until the transcript confirms. |
| 10 | Composer layout **K4** (settings column on the right) on 120 columns or more, **K3** (status line and commands) below. K1 and K2 rejected. |
| 11 | The composer editor is **rasterized** as the target, behind the latency gate; the hybrid cell composer ships first and stays as the fallback. |

Naming note: `thread` collides with `std.Thread` in grep. Domain code lives
under a `threads` capability namespace (`src/backend/threads/`,
`src/frontend/threads/`) so a search for `threads.` finds the domain and a
search for `std.Thread` finds the OS.

## The problem

The multiplexer (workspace → tab → pane) is right for terminal work: one
command, its result, an agent beside an editor, atomic interactions. It is
wrong for supervising agents. Moving between agents is not smooth, a
directional key inside Neovim can land on a pane the user did not mean, the
sidebar lists agents but offers no control over them, and a conversation is
only readable as raw terminal output. The multiplexer must stay as it is. What
is missing is a second projection of the same runtime that is agent-first, and
a cheap way to switch between the two.

## What the field converged on

Verified from product docs, changelogs and issue trackers (see the source list
at the end).

1. **The unit of work is a bundle.** T3 Code (thread), Conductor (workspace),
   Vibe Kanban (workspace), Emdash (task), Zed (thread), Claude Code Desktop
   (session), Codex app (thread) all name the same thing: one branch, one
   directory, one conversation, one terminal, one diff. Conductor says it
   plainly: "the branch is still the core unit that explains what a
   workspace is".
2. **Two levels, not three.** Project → unit. Sub-conversations (Vibe Kanban
   sessions, Emdash conversations, Claude's side chat) hang off the unit.
3. **Durable thread, disposable session.** T3 Code's glossary separates the
   thread ("the durable conversation and work history for a project. It
   survives provider process exits") from the session ("the provider runtime
   attached to a thread"). This is the same split telar already made between
   runtime and client, applied one level up.
4. **Five states, not two.** herdr, Warp, Superset and cmux distinguish
   working, blocked (needs input), done (finished, unseen), idle (seen) and
   unknown. Every tool that shipped with two states had to add "needs input"
   later (T3 Code #442, cmux #2576).
5. **Attention is a view, not a badge.** Superset's workspaces page groups by
   "Needs attention, Working, Needs review, Idle, Merged"; Codex has a triage
   inbox filterable by unread; Cursor has a "needs attention" section. Global
   badges drift from the sidebar (Cursor forum, staff: "we're telling two
   different stories"). Unread must clear only when the user looks at the
   unit, which is what telar's `done` → `acknowledge_agent` already does.
6. **Terminal beside conversation**, reached by one chord (`Cmd+J`,
   `` Ctrl+` ``, `mod+g`). Terminal-first tools (Superset, Emdash, cmux) make
   the pty the unit and put the chat on top of it.
7. **Diff is a file list plus line comments sent in one batch** (Conductor,
   Vibe Kanban, Claude Desktop, Codex app, Superset with persistent "Viewed").
8. **Archive is not delete**, with auto-archive when the PR merges.
9. **Navigation**: next/previous unit, digits 1-9, fuzzy palette, recents.

The pain that recurs across HN threads and issue trackers:

- "Which one is waiting for me?" is the first complaint everywhere
  (Conductor HN, claude-code #36885, T3 Code #442, cmux #2576, Superset HN).
- Ambiguous state: needs-input vs idle vs done-unreviewed; ghost runs.
- Worktree sprawl: cleanup, untracked files, ports, one setup per worktree.
- Review is the bottleneck, and no tool makes merging to main easier.
- UI scale: 78 tasks stall an Electron app; 2 GB of RAM.
- Bad titles make old threads impossible to find (Zed #42381).

The terminal-native tools (herdr, Claude Squad, ccmanager, agent-deck, Gas
Town, opencode, the tmux, zellij and wezterm agent plugins) add what a TUI
specifically needs:

- **Two-layer detection with an explanation.** Hooks are authoritative,
  screen patterns are the fallback, `blocked` is deliberately conservative,
  and `herdr agent explain` says which rule produced the verdict. telar's
  `telar agent get --json` already reports source, confidence and authority.
- **State rolls up.** A blocked agent makes its tab and workspace look
  blocked (herdr); tmux plugins badge the window title. A project count is
  the same idea one level up.
- **One key for "the next one that needs me".** recon `i`,
  tmux-agent-status `prefix+N`, cmux `⌘⇧U`, agent-deck `ctrl+b 1-6`.
- **Two listing axes**: by project (herdr Spaces, agent-deck groups) and flat
  by state (herdr Agents panel, `/@` filters). Users replaced herdr's goto
  picker twice because it "rendered too much and didn't focus its search by
  default" (herdr-goto, herdr-configurable-picker).
- **List plus preview** everywhere; **reply without attaching** (claude-squad
  #312 "focus mode", Agent-Manager "press space on a blocked agent").
- **Threads form a graph**: Amp forks, handoffs and a thread map; agent-deck
  fork; opencode `session_parent` for subagents.
- **Blind scrollback is the pain no TUI solves.** cmux #11953: "Once a
  Claude Code / Codex conversation grows to hundreds of turns, the only way
  back to an earlier exchange is blind scrolling through terminal
  scrollback." Claude Code renders in the alternate screen, so its earlier
  output never reaches the host scrollback (claude-code #42670, #40253);
  herdr documents the same caveat and tells users to ask the agent to write
  a markdown file. This is why a conversation view built from the agent's
  files is not a luxury.
- Pickers that close and lose sight of the background (opencode #24451),
  keybinding conflicts (herdr HN thread), stdin races on attach (claude-squad
  #325) and typing latency with many panes are the other recurring
  complaints. telar's typed transport, key router and pacer already answer
  the last three.

Navigation models worth borrowing, all keyboard-first: lazygit's block cycling
(`tab`/`h`/`l`) with a screen mode that enlarges the focused block without
changing the layout; aerc's separate key contexts for the list and the
message with read/unread semantics; yazi's Miller columns
(parent → current → preview); gh-dash's sections defined as saved queries;
k9s's view stack that `Esc` unwinds.

## What the data allows

Measured on this machine on 2026-09-06 and verified in agent docs.

- Claude Code writes `~/.claude/projects/<encoded cwd>/<session>.jsonl`.
  Records seen: `user`, `assistant`, `system` (subtypes
  `stop_hook_summary`, `turn_duration`, `compact_boundary`), `attachment`,
  `ai-title`, `last-prompt`, `custom-title`, `mode`, `permission-mode`,
  `queue-operation`, `file-history-*`. Tree by `uuid`/`parentUuid`. Content
  blocks `text`, `thinking`, `tool_use`, `tool_result`. Claude Code now
  writes its own generated title as `ai-title` records (49 updates in one
  session). Anthropic documents the format as internal and changing;
  `sessions-index.json` is unreliable (seven open issues). Subagent files
  carry no reference to the parent; only the `SubagentStart` hook links them.
- Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` with
  `session_meta` (cwd, git branch/commit/url, cli_version), `response_item`
  (`message`, `reasoning`, `custom_tool_call`, `custom_tool_call_output`),
  `event_msg` (`task_started`, `task_complete`, `item_completed`,
  `token_count`), `turn_context`, `compacted`. Names live in
  `state_<n>.sqlite` (`threads.name`), which telar already reads.
- Pi writes `~/.pi/agent/sessions/<encoded cwd>/<ts>_<uuidv7>.jsonl` with a
  `session` header, `session_info{name}`, `message` records (roles `user`,
  `assistant`, `toolResult`, `bashExecution`) as a tree by `id`/`parentId`.
- opencode keeps SQLite (`session`, `message`, `part`, `project`,
  `permission` tables) and exposes `opencode serve` with SSE events.
- Line sizes: up to 132 KB in Claude files, 460 KB in Pi files, 2.3 MB in
  Codex rollouts. Volume: 167 Claude sessions (708 MB), 1861 Codex rollouts
  (6.6 GB), 19 Pi sessions. Any reader is incremental, by offset, with a
  per-line cap and a skip policy.
- Hooks are the reliable link between a pane and its file: Claude Code,
  Codex and Gemini deliver `session_id`, `transcript_path` and `cwd`; Pi
  delivers them through its extension API. telar already installs all three
  and already watches the file for `/rename`.
- Compaction is only recoverable from disk (`compact_boundary`,
  `compacted`, `compaction.firstKeptEntryId`). Reconstructing conversations
  from proxied traffic works for Anthropic Messages with dedupe across
  requests (claude-trace does it), but Codex uses `store=false` with an
  incremental WebSocket transport, subagents share the pane credential, and
  side calls (Haiku titles, suggestions) pollute the stream. The proxy stays
  what it is today: lifecycle and command evidence.
- Tool calls pair by id (`tool_use_id`, `call_id`, `toolCallId`) and the
  result always arrives later. ACP's vocabulary (`kind` read/edit/delete/
  move/search/execute/think/fetch/other, `status` pending/in_progress/
  completed/failed, `locations`, `rawInput`/`rawOutput`) is a good internal
  model even though telar does not speak ACP.
- Attention signals are not uniform: Claude Code has twelve
  `notification_type` values, Codex `notify` has one event, Pi has
  `extension_ui_request`, opencode has `permission.asked` and
  `question.asked`. telar's `AgentReportState` is already the adapter.
- Attaching to a running interactive session is impossible for Claude Code
  and Pi; Codex's app-server and opencode's server allow it. Owning the
  runtime means launching the agent and reading its files, not attaching.
- Rendering conventions converge in every viewer (claude-code-log,
  claude-code-trace, Claude Code's own `Ctrl+O`, opencode `/details`): the
  user prompt is the navigation anchor, a tool call is one expandable line,
  thinking is hidden by default, diffs render inline only for edits,
  compaction is a boundary, tokens per message.

## What telar already has

Verified in the tree at `79f0506`.

- Runtime agent aggregate per pane generation with provider, projected
  status (`unknown/working/blocked/ready/failed/done`), source, authority,
  confidence, session reference, title with source precedence, cwd and
  workspace/tab/pane labels; at most 64 in a snapshot
  (`src/core/schema/types.zig:447`).
- `done` as unseen `ready`, cleared by `acknowledge_agent` from the client
  whose focused pane hosts the agent (`docs/flows/agent-done.md`).
- Hooks for Claude Code, Codex and Pi reporting lifecycle, session reference,
  session file, title and shell tool calls; proxy turn completion for the
  Anthropic and OpenAI dialects; manifests as data.
- Session file watches keyed by pane generation, one probe in flight,
  incremental reads by offset (`src/backend/agent/session_file.zig`,
  `transcript.zig`, `session_readers/`).
- Checkpoint with `agent_provider`, `agent_session`, `agent_title` per pane
  and resume through an allowlisted argv (`src/backend/persistence/`).
- History DB with `session` (title), `command` (author, origin, provider,
  `tool_call_id`) and `command_output`, FTS5, bounded paging
  (`src/backend/history/persistence/sqlite.zig:14-89`). No transcript.
- Client composition root `composition.render`
  (`src/frontend/widgets/composition.zig:55`), a single caller in
  `presentation/view.zig`, `Regions.calculate` for geometry. No mode concept
  on `ClientModel`; modes are optional states (`copy_state`, `name_prompt`).
- The sidebar declares its non-goal in its first lines: "It has no task
  taxonomy, filters, tabs, or task actions"
  (`src/frontend/widgets/sidebar.zig:1-5`). That sentence is the seam.
- Generic list modal (`widgets/goto_picker.zig`), two-pane browser with an
  inspector (`widgets/history_browser.zig`), the name prompt with seven
  targets and a single-line editor (`input/edit.zig`), fullscreen as
  client-only layout state, workspace bookmarks and cross-workspace handoff,
  command tabs, notification center with pane targets, `telar agent` and
  `telar pane` control API, worktree creation from the CLI, a git observer
  per workspace (branch + dirty).
- A graphics stack that is further along than "icons": FreeType and
  HarfBuzz are linked, JetBrains Mono is embedded, `graphics/rasterizer.zig`
  rasterizes text on the client, toasts are already rendered as KGP images
  keyed by their content (`graphics/toast.zig`: four 1.5 MiB RGBA images,
  256 KiB of encoded data per media pass, placement-only updates while
  animating), the hybrid sidebar draws a rounded card and provider marks
  under cell text, and `kitty-full` is reserved as "does not rasterize text
  yet" (`docs/kitty-graphics.md`). The per-frame transmission budget is
  256 KiB (`graphics/kitty_codec.zig:10`). Remote clients receive pixels in
  1 MiB chunks over the socket.
- Vocabulary already in `README.md`: a **hilo** is one agent session, "a
  thread of execution and a thread of conversation at the same time"; the
  **trama** is how they are laid out on screen. Those words stay as prose.

## Design

### Vocabulary

- **Project**: a git repository identified by its common directory (the
  main worktree path). Every worktree of that repository belongs to the same
  project. A directory that is not a repository is its own project keyed by
  path. This is what groups threads, and it is what Codex's app got wrong
  when it grouped by physical cwd and lost worktree threads (openai/codex
  #26875).
- **Thread**: the durable record of one agent conversation: provider, the
  agent's own session reference, project, cwd, branch, titles (the agent's
  and telar's), timestamps, last known status, where its transcript lives.
  A thread outlives its pane. It is runtime-owned and persisted in the
  history database.
- **Agent** (the live half): the pane generation currently running a
  thread's process, which is today's agent aggregate and `CONTEXT.md`'s
  "Agent". A thread has zero or one open agent. T3 Code calls this half a
  "session"; telar keeps that word for the agent's own session reference
  and files, never for the live half.
- **Multiplexer mode**: today's client. **Agent mode**: the projection
  described here. Both are views of one runtime; the mode is client state.

### Principles

1. **One runtime, two projections.** Nothing in the runtime knows which mode
   a client is in. The thread registry is mode-independent data that the
   multiplexer sidebar can also use.
2. **A live thread is always a pane in a tab in a workspace.** Agent mode
   never creates a second topology. It indexes the same panes by project and
   by attention. That is what makes switching free: toggling the mode
   changes composition, never runtime state.
3. **The terminal stays the truth.** The conversation view is a reading aid
   built from the agent's own files, linked by the hooks telar installs. It
   never parses the screen and never replaces the agent's input.
4. **Attention is a view.** Sections are computed from status and seen state.
   `done` clears only when the pane is focused in either mode, through the
   acknowledgement that exists today.
5. **Heuristics never authorize.** Actions that inject input from the thread
   list are enabled only when the status has `lifecycle_report` authority;
   otherwise the user enters the terminal and answers there.
6. **Bounded everything.** The client keeps replica pages the way the history
   browser does. Parsing runs in observation workers. The interactive path
   allocates nothing.
7. **Cells keep every function.** Graphics enrich; they never become the
   only way to read or act (`docs/engineering-invariants.md`, Graphics).
   Any graphical proposal below degrades to its cell twin without losing a
   key or an action.

### The screen

```text
┌ telar ▸ agents ────────────────────────────────────────────────────────────┐
│ PROJECTS       │ NEEDS YOU 2                │ fix proxy tests   claude  3m  │
│ ● telar    2/5 │ ● fix proxy tests  claude  │ telar › agents › pane 2  ⎇ fix│
│   gwagent  1/2 │ ● migrate schema   codex   │ [terminal]  conversation  chg │
│   site     0/1 │ DONE 1                     │                               │
│   archived  14 │ ✓ add asteroids    pi      │   the live pane, full column  │
│                │ WORKING 2                  │                               │
│                │ ◐ lua bars         claude  │                               │
│                │ ◐ perf gate        codex   │                               │
│                │ READY 1                    │                               │
│                │ · scratch          pi      │                               │
├────────────────┴────────────────────────────┴───────────────────────────────┤
│ j/k move  ⏎ open  i interact  tab view  n new  r rename  a archive  / find  │
└─────────────────────────────────────────────────────────────────────────────┘
```

Three columns. Projects on the left with a needs-you/total count per project
and an archived bucket. The inbox in the middle, sectioned by attention:
NEEDS YOU (`blocked`, `failed`), DONE (unseen), WORKING, READY (seen),
ARCHIVED collapsed. Inside a section, most recent state change first. The
thread view on the right with three tabs: **terminal** (the attached pane,
default), **conversation** (rendered transcript), **changes** (git).

Narrow terminals degrade like a mail client: under about 120 columns the
projects column becomes a one-row strip above the inbox; under about 90 the
inbox and the view alternate (list ⇄ detail). `Regions.calculate` already
owns this kind of minimum-width policy for the sidebar.

This is the skeleton, and it is the chosen layout (proposal A below). The
conversation is a view tab, not a drawer. A composer widget sits at the
bottom of the view column whenever a thread is open or being created; see
"Provider independence and the composer".

### Navigation

Agent mode has two focus states.

- **Browse**: keys go to telar. `j`/`k` move, `Enter` opens the selected
  thread in the view, `i` (or `Enter` again) enters interact, `Tab` cycles
  the view tabs, `h`/`l` move between the three columns, `1-9` select
  projects, `/` filters (with agent-deck's status prefixes: `@` needs you,
  `!` working, `#` ready), `n` new thread, `r` rename, `a` archive, `p`
  quick prompt, `z` zooms the view column over the other two, `g` jumps to
  the next thread that needs you. The view header always says why a thread
  is in its state: `blocked · hook report` or `blocked · screen`, the
  explanation `telar agent get --json` already gives.
- **Interact**: keys go to the thread's pane exactly as in multiplexer mode.
  Nothing else changes; `ctrl+h/j/k/l` reach Neovim because there are no
  telar splits to move to. A single chord returns to browse (default
  `prefix` then `Esc`; a global `ctrl+alt+` chord is offered in the config
  because herdr mapped ten terminals and two desktops and found that family
  free). `ctrl+alt+j`/`ctrl+alt+k` move to the next/previous thread without
  leaving interact.

Selecting a thread whose pane lives in another workspace uses the agent
navigation flow that already exists (`planAgentNavigation`: local tab select
and focus, or a workspace handoff with a bookmark of the workspace being
left). The view column shows the focused pane of the active tab with the
fullscreen geometry policy, so the child is resized once to the column and
hidden panes in that tab keep parsing without render work. Switching back to
multiplexer mode lands where the thread lives, with the tab layout restored
from the bookmark. This reuses every mechanism the sidebar click uses today.
Decided in review: P0 ships this; attaching panes outside the projected
workspace is a runtime change and is not planned unless the handoff proves
annoying with the prototype in hand.

### Interaction

What the review asked to pin down: how a conversation starts, how a message
is added, how a running thread is prompted, how a conversation is navigated,
and how all of it sits on the multiplexer's model.

**Starting a thread.** `n` in browse opens the composer in "new thread"
form: project (defaults to the selected one), provider (the manifest list),
the provider's options (model, effort, permission mode, whatever its
manifest declares), worktree (none, or a new branch name), and the first
prompt in the multi-line editor. `ctrl+Enter` creates. The runtime composes
`create_workspace` for the project when none is open, `create_tab` titled
after the thread, `create_pane` with the argv built from the manifest's
allowlisted `launch` plus the validated option values, and sends the first
prompt through `send_pane_text` once the agent reports `ready`. The thread
appears in WORKING the moment the prompt is accepted. `telar thread new
--project --provider --option model=opus --worktree --prompt` is the same
flow from a script or from another agent. Decided: where it lands in the
multiplexer is one workspace per project, one tab per thread, one pane. A
thread started from a shell in multiplexer mode (the user just types
`claude`) is adopted the same way the sidebar adopts it today, so nothing
forces the composer.

**Adding a message.** Two paths, by design:

- *Interact.* Keys go to the agent's own composer. This is always available,
  it is the only path that answers a permission prompt (principle 5), and
  the image shelf (`Ctrl+V`) keeps working because it is the pane's input.
- *The composer from browse.* `p` focuses the multi-line composer at the
  bottom of the view column (decided: a built-in widget, not the name
  prompt). `ctrl+Enter` sends through `send_pane_text` in prompt mode:
  bracketed paste when the child enabled it, then Enter. `ctrl+e` still
  hands the draft to `$EDITOR` in a transient command tab for those who
  want it. Refused while `blocked`, as today. While `working`, the text
  reaches the agent's own input queue; what each agent does with input typed
  during a turn (Claude Code and Codex queue it, Pi's RPC distinguishes
  `steer` from `follow_up`) is an assumption to verify per agent before
  promising "queue" semantics in the UI.

**Answering a permission.** Only in interact. The thread row and the view
header show what is being asked (`wants: Bash zig build test`) when the
evidence is a hook report that carried `tool_name` and `tool_input`; the
registry keeps that as a bounded `blocked_reason` (256 bytes). A screen-only
`blocked` shows no reason, only the state.

**Navigating a conversation.** In the conversation view: `j`/`k` lines,
`{`/`}` previous/next user prompt, `[`/`]` previous/next tool call, `Enter`
expands or collapses a tool call, `o` toggles the outline (only prompts and
tool summaries, `Enter` jumps), `/` searches the loaded page, `t` shows
thinking, `y` copies the message through OSC 52, `G` returns to the tail and
re-arms following, `gg` goes to the top. `Tab` switches to the terminal of
the same thread. Compaction boundaries are separators the outline lists too.

**Moving between threads.** `j`/`k` in the inbox, `g` for the next thread
that needs you, `ctrl+alt+j`/`ctrl+alt+k` from interact, `1-9` for projects,
`/` to filter, and the goto picker (`prefix+g`) gains threads, archived ones
included, so a closed conversation is one fuzzy search from being resumed.

**Lifecycle keys.** `a` archives: on a live thread it asks, then closes the
pane and keeps the record; on a closed one it hides it. `R` resumes an
archived thread in a new tab of its project. `f` forks a thread (the agent's
own fork flag; relation `fork` in the registry). `r` renames the telar title;
the agent's own name keeps its precedence. `x` kills the process after
confirmation and leaves the thread closed but not archived.

**Mouse.** Everything above is reachable by click: threads, projects, view
tabs, tool-call expanders, the composer and its selectors. The hit registry
that the sidebar and top bar already use covers it; nothing in agent mode is
keyboard-only.

### Provider independence and the composer

Nothing in agent mode names a provider. The three places where provider
knowledge lives are the ones telar already has, and they are data or
adapters, never UI code:

1. **Manifests** (`runtime.agents`, `docs/flows/agent-manifests.md`) say how
   to recognize, show and launch a provider. They gain a `launch` argv
   (built-ins only, allowlisted like `resume`), a list of **options** the
   composer exposes, and optional **live commands** for changing an option
   on a running session through the agent's own slash command.
2. **Session readers** (`session_readers/{claude,codex,pi}.zig`) are the only
   provider-specific parsing, keyed by `transcript_kind`. They also report
   the model in use: Claude's assistant records carry `message.model`, Pi
   writes `model_change` records, Codex writes `turn_context`. The registry
   stores it as `model` and shows it in the composer header.
3. **Hook installers** (`telar integration install <agent>`) know the hook
   formats.

The composer is the same widget for a new thread and for a running one:

```text
┌ new thread ── project telar ▾ ── provider claude ▾ ── worktree none ▾ ─────┐
│ model opus ▾   effort high ▾   permissions default ▾                        │
├──────────────────────────────────────────────────────────────────────────────┤
│ Fix the failing proxy tests in src/backend/proxy, keep the relay untouched. │
│ ▌                                                                            │
└ ctrl+enter create · tab next field · ctrl+e $EDITOR · esc close ────────────┘
```

For a running thread the first row shows the thread's project and provider
fixed, and the option row shows the current values from the registry.
Decided in review: changing one there sends the manifest's live command
(`/model opus` in Claude Code and Codex, `/model` in Pi) before the prompt,
and the change is confirmed only when the session reader sees it in the
transcript; the header shows `model opus (pending)` until then. Providers
whose manifest declares no live command show the value read-only.

Option values are validated at config load like every manifest field: an
enumerated option accepts only its listed values; a free-text option (a
model id the list does not know) is capped at 64 bytes, must not start with
`-`, and is passed as its own argv element after the flag, never through a
shell. The runtime reconstructs the argv from the validated values; nothing
persisted or received over the wire is executed as-is. `create_thread`
carries `(option_key, value)` pairs, at most 8, and the runtime rejects
keys the manifest does not declare.

What the built-ins ship, verified against `--help` on this machine:

| Provider | Launch | Options in the composer | Live command |
| --- | --- | --- | --- |
| claude 2.1.263 | `claude` | `--model <m>`, `--effort <level>`, `--permission-mode <mode>`, `-n <name>` from the thread title | `/model <m>` |
| codex 0.153.4 | `codex` | `-m <model>`, `-c model_reasoning_effort="<level>"`, `-s <sandbox>`, `-a <approval>`, `-p <profile>` | `/model <m>` |
| pi 0.85.1 | `pi` | `--provider <name>`, `--model <pattern>`, `--thinking <level>` (off, minimal, low, medium, high, xhigh, max) | `/model` |

`client.agent_mode.defaults = { claude = { model = "opus", effort = "high" }
}` sets the values the composer opens with, per provider and optionally per
project. The value lists are data too, so a new model name is one line of
config, not a release.

### Composer alternatives

The review asked for concrete composer designs based on T3 Code's. Verified
in the local checkout (`~/sandbox/t3code`, 2026-07-07,
`apps/web/src/components/chat/ChatComposer.tsx:2402-2760`): T3's composer is a
card with the editor on top and a footer toolbar; left: provider + model
chip (a popover with a provider rail, favorites, search and `#1..#9`
jumps), an effort chip (a radio menu built from the provider's option
descriptors), the Plan/Build toggle, the runtime mode select (Supervised /
Auto-accept edits / Full access) and MCP; right: a context-window meter and
the send button, which becomes stop while a turn runs. Above the editor,
mutually exclusive: the pending-approval panel (editor disabled, Approve
once / Approve for session / Decline / Cancel, keys Y N Esc), the plan
questions panel, or the follow-up banner. Enter sends, Shift+Enter inserts a
newline, Shift+Tab toggles Plan/Build. No queue, no "send after turn", no
prompt history. Images by paste or drag only. Triggers `@` files, `$`
skills, `/` commands (`/model`, `/plan`, `/default`). A new thread has no
form: the same composer on a draft, with an environment / local-or-worktree
/ branch toolbar below it, and the title derived from the first prompt. The
provider locks once the thread starts; model and effort are stored per
provider and per thread with sticky global defaults.

Four alternatives for telar, all sharing the same data (manifest options,
model from the transcript, context from usage records over a declared
window) and the same keys (`Enter` sends, `alt+Enter` newline because
Shift+Enter needs the kitty keyboard protocol, `ctrl+e` to `$EDITOR`,
`ctrl+x` stop, `Esc` back to browse, `up`/`down` history of 32 prompts):

Decided in review: **K4** is the design, with **K3** as its form under
120 columns; K1 and K2 stay documented as considered.

- **K1, footer bar (considered).** Editor on top, chips below: provider +
  model, effort, mode on the left; context meter and send/stop on the right.
  Each chip opens the existing list modal with search and `1-9` jumps;
  chords `ctrl+m`, `ctrl+r`, `ctrl+p`. Editor plus three rows. Collapses
  into a `…` menu under about 70 columns, as T3 does at 620 px.
- **K2, header row (considered).** The selectors as a labelled form row
  above the editor. Reads well for the first thread, heavy on every open
  thread.
- **K3, status line (the narrow form).** A bare editor and a status line
  (`claude · opus · high · supervised · ctx 38%`); changes through
  `/model`, `/effort`, `/mode` with completion, the same `/` trigger T3 uses
  for `/model`. Least chrome, lowest discoverability.
- **K4, side column (the design).** On terminals of 120 columns or more
  the settings stack in a column to the right of the editor: provider,
  model, effort, mode, context, and the primary action (send / queue /
  stop / create) at the column's foot; for a new thread the column also
  holds project, worktree, base and branch, so no bar is needed under the
  composer. Below 120 columns it becomes K3. Two layouts to keep, which is
  the accepted cost.

States, fixed by `mocks/11-composer-state-working.txt` through
`14-composer-state-new-thread.txt`: running (the action becomes
"queue", stop appears and sends the manifest's interrupt key), pending
approval (editor replaced by the question, `y`/`a`/`n` forward the agent's
own answer, only with hook authority; screen evidence offers only `i`),
live change pending (the model value shows `(pending)` until the reader
confirms), new thread (no form; project, worktree, base, branch, provider
and options in the column; title from the first prompt). Images and `@`
file mentions come after P1: the image strip hands files to the agent
through its manifest attachment scheme, and `@` completes from a bounded
`git ls-files` in a worker.

**KGP in the composer.** Decided in review, in two steps: the hybrid layer
ships in P1 as the first bounded use of the C pipeline, and the editor
itself is rasterized as the target (phase P2r below). Cells keep the text, cursor, selection, hit targets
and the host font. KGP paints under them: the rounded frame (T3 draws a
22 px gradient frame), each chip's fill with the provider mark from the
atlas, the context ring (T3 draws a donut), thumbnails of pasted images,
the red approval band, a pulsing outline on a pending chip (placement-only
animation, as the sidebar's working glyph), and the KGP border of the model
popover. Everything reuses existing pieces: the toast pipeline's raster keys
and placement-only updates, the sidebar's card and provider atlas, the modal
border, the attachment preview shelf that already decodes and plans
thumbnails on the media worker. Bounds: one frame, at most eight chips, one
ring, at most eight 64 px thumbnails, keyed by content; a freshly opened
composer fits inside the 256 KiB per-frame budget. Without KGP it is K4 in
cells.

**The rasterized editor (P2r).** Decided: the prompt text is drawn as an
image, with proportional type, minimal markdown (bold, italic, code spans in
JetBrains Mono, lists; no tables), inline thumbnails, telar's own caret and
selection, copy through OSC 52. What it is made of:

- One model, two renderers. `input/text_area.zig` owns the buffer (8 KiB),
  the cursor by grapheme cluster, the selection and the history. The cell
  renderer is K4 and stays as the fallback. The raster renderer
  (`graphics/text_layout.zig`, `graphics/composer_raster.zig`) shapes with
  HarfBuzz, breaks lines at spaces and hard breaks to the editor's pixel
  width, and draws one image per visual line, so a keystroke re-rasters one
  line and scrolling or caret blink are placement changes.
- A second embedded face for prose (an OFL proportional font, about 300 KB)
  beside JetBrains Mono for code. The font seam with the agent's pane is
  accepted: the composer is meant to look different, as it does in T3.
- Input: the terminal cursor is hidden while composing and the caret is an
  image; IME composition text arrives already composed, so there is no
  preedit rendering; mouse maps pixels to clusters with mode 1016 and falls
  back to cell centers without it.
- Transport: only local or shared-memory clients get the raster editor;
  remote clients over SSH receive pixels in 1 MiB chunks and stay on K4.
- Budget: an editor of 60 columns by 6 lines is about 316 KB of RGBA in
  full and about 50 KB per line; a keystroke transmits one compressed line.
  At most 64 visual lines.

This is the first place where the visible echo of a keystroke passes
through the media path, which the invariants forbid today. It is recorded
as an explicit exception in `docs/engineering-invariants.md` with a gate:
the benchmark must show a one-line echo at p99 under one pacer interval
(16.7 ms) on the local transport, and a session that misses it falls back
to the cell renderer while the pane never waits. The gate is P2r's
completion criterion; if it fails, the composer stays hybrid.

The widget itself: `input/text_area.zig`, a bounded multi-line editor (8 KiB,
the `send_pane_text` chunk size) with cursor movement, word wrap inside the
view column, a prompt history (`up`/`down` at the first line, 32 entries per
thread kept in the client), and the selector row driven by the name-prompt
editor's key handling for the dropdowns. Image attachments stay with the
pane's shelf in interact for P1; carrying an image from the composer into
the agent's input is a later step because each provider names pasted images
differently (`attachments` in the manifest already encodes that).

### Mode switch

`telar.action.toggle_agent_mode()` (default `prefix` then `a`). `ClientModel`
gains `mode: enum { multiplexer, agent }` and an `AgentModeState { focus:
browse | interact, project, selected: ?ThreadKey, view: terminal |
conversation | changes, scroll, filter }`. The mode and the selection travel
in `update_client_layout` next to sidebar visibility so a reconnecting client
comes back in the mode it left. Hover, scroll and filter die with the client.

### The registry

A new `thread` table in the history database, owned by the runtime and
written through `history.Service` on the observation path:

```text
thread(id, provider, session_ref, project_key, project_path, cwd, branch,
       title_agent, title_telar, title_source, transcript_path,
       transcript_kind, started_at_ms, ended_at_ms, last_status,
       last_change_ms, blocked_reason, model, options, archived, pane_id,
       pane_generation, parent_id, relation)
```

`model` is what the session reader last saw in the transcript; `options` is
the validated `(key, value)` set the thread was launched with, so resume and
fork can offer the same configuration. `parent_id` and `relation` (`resume |
fork | subagent | handoff`) make the registry a graph from day one. Resume and fork come from the hooks'
`SessionStart` trigger (`resume`, `fork`, `compact`), subagents from
`SubagentStart` (`agent_transcript_path`) and Pi's session `parentSession`,
handoff from the thread the user created the new one from. The UI shows the
graph as a fold under the parent, the way aerc folds a thread; nothing more
until it earns it.

Sources, in order of authority:

1. The tracker, when an agent acquires a session reference (hook report,
   Pi extension event, or the proxy for the Anthropic dialect): upsert with
   provider, reference, cwd, transcript path and kind. Status transitions
   update `last_status` and `last_change_ms`; exit sets `ended_at_ms`.
   Titles follow the precedence the aggregate already enforces.
2. The project key from a git probe in the existing git observer:
   `git rev-parse --git-common-dir` resolved against cwd, cached per cwd,
   never on the interactive path.
3. The user: rename, archive, unarchive, from the UI or `telar thread`.
4. Import, optional and explicit: `telar thread import` scans the Claude
   project directories, Codex `session_meta` records and Pi headers for
   sessions telar never saw. Bounded, resumable, observation path.

Wire: `query_threads { project?, statuses, archived, text, cursor, limit ≤
100 }` answered by `thread_list` with 96-byte titles, 1 KiB paths and a next
cursor; `archive_thread`, `rename_thread`, `resume_thread`, `create_thread`.
The client keeps one bounded page like the history palette and overlays live
status from the agent snapshot by session reference.

Resume from the list launches the allowlisted resume argv the checkpoint
restore already uses, in a new tab of the project's workspace, creating the
workspace from `project_path` when none is open. New thread is the composer
described under "Interaction"; it composes `create_workspace` (with
`--worktree` semantics moved into the runtime launch transaction or kept in
the client as the CLI does today), `create_tab` and `create_pane` with the
argv built from the manifest's launch and the validated options, then sends
the first prompt through `send_pane_text` once the agent reports `ready`.

### The conversation view

A `SessionReader` per provider generalizes the title watch: Claude transcript,
Codex rollout, Pi session, opencode SQLite later. Each reader tails its file
by offset, parses one record at a time in an observation worker, skips any
line above a cap (256 KiB; measured maxima are 132 KB, 460 KB and 2.3 MB, and
the oversized ones are tool outputs) and leaves a stub with the byte count.
Records normalize to one `ThreadItem`:

```text
item(thread, seq, kind: user | assistant | thought | tool_call | tool_result |
     compaction | title | subagent | system, tool_id, tool_kind, status,
     preview ≤ 512 B, file_offset, byte_len, ts)
```

Decided in review: only the index and the preview are stored (a new
`thread_item` table); the full text stays in the agent's file and is read on
demand through `read_thread_item` with a 64 KiB cap, the same shape as
`read_history_output`. This keeps telar's database small, avoids copying
gigabytes of tool output, and respects the rule that response bodies are not
persisted until a redaction policy exists. FTS over user-authored previews
gives "find the thread where I asked about X" without indexing model output.

`query_thread_items { thread, cursor, limit ≤ 100 }` answers `thread_items`;
the client keeps one page in fixed storage. Following a live conversation
costs one file probe per second per followed thread, bounded to the threads
currently open in a conversation view plus live agents, at most 16 files.

The widget renders what every viewer converged on: user prompts as anchors
(`{`/`}` jump between them), assistant text wrapped with light markdown
(headings, fences, lists), a tool call as one line (`» Bash  zig build test
→ 0  1.8s`) expandable with `Enter`, thinking hidden behind `t`, edits as
inline ± lines when the tool input is a diff, compaction as a separator,
tokens per assistant message when the record carries usage. `y` copies a
message through OSC 52. At the bottom the view follows the tail; scrolling up
pins it.

### The changes view

The git observer gains a file list (`git status --porcelain`, at most 256
entries) per workspace or worktree, on the same 5-second cadence. The widget
lists files with their status; `Enter` on a file opens a transient command
tab in the view column running `client.agent_mode.diff_command` with the
path (default `git diff --`; `delta`, `difftastic` or `lazygit` are one
config line away). telar does not parse diffs. Later, per-file notes
collected in the widget compose one prompt sent through `send_pane_text`,
the batch comment pattern the graphical tools share.

### Attention and views

Sections come from the status enum and `seen`; `failed` joins NEEDS YOU
because a failed exchange needs a human too. Sorting inside a section is by
last change, newest first. Project counts show needs-you over total. A later
phase lets configuration declare views as data, the way herdr's
`agent.view.set` does but static: `client.agent_mode.views = { { name =
"focus", filter = ..., sort = ... } }`, validated at load, no Lua on the
interactive path.

The host terminal title carries the attention count (`2 need you · telar`)
through the existing OSC 0 path so the outer terminal and the inbox never
tell two stories.

### Interface proposals

Four looks over the same skeleton and the same keys. They differ in how much
of the chrome is drawn with KGP and in whether the terminal or the
conversation is the default face of a thread. Decided in review: A is the
layout, C is the target look, B and D stay documented as the alternatives
that were considered.

**A. Mail.** Three cell columns as drawn above. The terminal is the default
view tab. KGP enrichment exactly as the sidebar has it today: a rounded card
under the selected thread, provider marks, nothing else. Cost: the P0 work
and nothing more. Works over SSH and in any terminal. This is the fallback
every other proposal degrades to.

**B. Cockpit.** Terminal-first. The projects strip on top, a narrow inbox on
the left, and the thread's terminal filling the rest. The conversation is a
drawer that slides up from the bottom (`Tab`), the way Emdash and Claude
Desktop keep the terminal one chord away; the changes list is the drawer's
second tab. The pane keeps most of the width, which matters for Neovim
inside the agent's tab. Cost: the drawer is a second workbench rectangle in
`Regions`, and the pane is resized when the drawer opens (the fullscreen
geometry policy already handles one resize per toggle). Cells only, same
enrichment as A.

**C. Hybrid.** The layout of A or B, with the chrome drawn under the cells
by KGP the way the hybrid sidebar already works: a rounded card per thread
row, a soft bubble behind each conversation message, a coloured gutter for
tool calls and diffs, provider marks and avatars, image attachments shown
as thumbnails inline in the conversation, a thin progress or token bar per
assistant message. Text, cursor, selection and every hit target stay cells,
so copy, search and SSH fallback are untouched, and the host font stays the
host font. Cost: one raster key per card or bubble (the toast pipeline
already does this: raster on key change, placement-only updates otherwise),
bounded by the 256 KiB per-frame transmission budget, which means a
freshly opened conversation paints its bubbles over a few frames. Without
KGP it is A.

**D. Canvas.** The conversation view, and optionally the inbox, rasterized
as images: proportional typography (a second embedded face, about 300 KB),
real markdown, inline images at full resolution, smooth pixel scrolling,
bubbles and avatars. FreeType, HarfBuzz and the rasterizer exist; what does
not exist is a text layout engine, telar-owned selection and copy over that
layout, and the damage discipline that keeps a 1400×900 chrome inside the
per-frame budget (a full re-raster is about 5 MB of RGBA; per-message
images with placement-only scrolling are the only way it fits). The agent's
own pane stays cells beside it, so the canvas text must match the host font
or the seam shows; with JetBrains Mono embedded and Ghostty defaulting to it
the seam is invisible on this machine and visible elsewhere. Remote clients
over SSH receive pixels in 1 MiB chunks and would fall back to C or A. Cost:
the largest by far, and `kitty-full` is the reserved name for exactly this.

Decided: A as P0 because everything else needs its skeleton, C as the look
because it gives most of the "GUI in the terminal" feeling without breaking
a single invariant or the host font, and D only as a later experiment on the
conversation view if bubbles and thumbnails are not enough. B is not
pursued; the composer at the bottom of A's view column gives the terminal
the width it needs when the view tab is `terminal`.

### Deliberately not built

- A chat composer that replaces the agent's own input. The quick prompt is a
  convenience over `send_pane_text` and is refused while blocked, as today.
- Transcript reconstruction from the proxy. It fails for Codex, loses
  compaction, and cannot separate subagents.
- Screen scraping for conversations. The screen stays a lifecycle fallback.
- Copying assistant and tool text into telar's database.
- Grids of simultaneous chats, kanban boards, embedded browsers, containers
  per task, and approve keys for a `blocked` that only screen evidence
  reported: the composer forwards `y`/`a`/`n` to the agent only behind a
  hook report.

## Ownership, budgets and bounds

| Piece | Owner | Budget | Bounds |
| --- | --- | --- | --- |
| Mode, focus state, selection, filter | client | interactive | fixed struct, no allocation |
| Projects and inbox rendering | client | interactive | from the 64-entry snapshot plus one 100-row thread page |
| Thread registry | runtime, history worker | observation | 96 B titles, 1 KiB paths, 256 B blocked reason, 100 rows per page |
| Project key probe | runtime git observer | observation | one probe in flight, 5 s cadence, cached per cwd |
| Session readers | runtime workers | observation | 256 KiB per line, 64 KiB per item read, 16 followed files |
| Item index | runtime, history DB | observation | 512 B previews, FTS over user items only |
| Resume, new thread, fork | runtime launch transaction | observation | allowlisted argv, validated references |
| Composer | client `text_area` widget, transient `$EDITOR` tab | interactive | 8 KiB buffer, 32 history entries per thread, 8 options per thread, 64 B per free-text value |
| Changes list and diff | runtime git observer, transient pane | observation | 256 files, user's diff command |
| Composer KGP layer (hybrid) | client media path | media | one frame, ≤ 8 chips, one ring, ≤ 8 thumbnails of 64 px, keyed by content; K4 in cells without KGP |
| Rasterized composer editor | client media path, gated | media, explicit exception | one image per visual line, ≤ 64 lines, ~50 KB RGBA per line; echo p99 < 16.7 ms or fallback; local or shared-memory transport only |
| Graphical chrome (C, D) | client media path | media | 256 KiB encoded per frame, raster keyed per card or message |

Lifecycle: a thread is created on the first session reference, updated on
every status change, closed on exit, archived by the user, resumed through
the allowlist. Client death loses mode state only if the runtime layout
replica was not updated; reconnect restores the mode from
`update_client_layout`. Recovery: a corrupt or oversized session file
degrades the conversation view to "unavailable" with the terminal tab still
working; a missing hook leaves the thread without transcript path and the
view says so; media failure removes graphical placements and leaves the cell
chrome complete.

## Phases

Ordered by dependency. Each phase ends with tests, a flow document under
`docs/flows/`, `zig build test` and the perf gate.

```text
P0 agent mode, client only ──┐
                             ├─> P2 conversation view ──> P4 views, search, look
P1 registry, resume, new ────┤
                             └─> P2r rasterized composer editor (latency gate)
P3 changes view (independent after P0)
```

### P0. Agent mode over the agent snapshot, client only

No new messages. Everything renders from data the client already holds:
`agents.Snapshot`, `workspace_list.Snapshot`, tab models. The only wire
change is two fields in `update_client_layout` (mode and selection), which
bumps the fingerprint like every layout extension before it.

- `src/frontend/client/model/root.zig`: `mode`, `AgentModeState`,
  transitions (`toggleAgentMode`, `selectThread`, `enterInteract`,
  `leaveInteract`, `setView`); a `Version.agent_mode` dimension.
- `src/frontend/widgets/layout.zig`: `Regions.calculate` variant for agent
  mode with the three-column and degraded geometries (or the cockpit
  geometry if B is chosen).
- `src/frontend/widgets/composition.zig`: one branch on `input.mode`; new
  `widgets/agent_mode/{projects,inbox,view}.zig`. Projects derive from
  workspace paths until P1 provides the registry; the inbox sections derive
  from status and `done`.
- `src/frontend/input/action.zig`: `toggle_agent_mode`, `thread_next`,
  `thread_prev`, `thread_next_attention`, `agent_mode_interact`,
  `agent_mode_browse`, `agent_mode_zoom`, `agent_mode_view { terminal |
  conversation | changes }`, `agent_mode_select_project { u8 }`. Defaults in
  `config/default_bindings.zig`.
- `src/frontend/client/application/input/key_routing.zig`: `Authority`
  gains `agent_mode_browse`; the browse owner consumes semantic keys before
  the pane. Interact leaves routing untouched.
- View column = the focused pane of the active tab rendered with the
  fullscreen geometry policy (`DeliverPaneGeometryHandler`), selection
  through the existing `NavigateAgentHandler`.
- `update_client_layout` carries the mode and selection; the runtime replica
  stores them like sidebar geometry.
- Tests: model transitions and version isolation; routing ownership in both
  focus states; composition snapshot at three widths; reconnect restores the
  mode; the client test proves a cross-workspace selection performs one
  handoff and one resize. Flow doc `docs/flows/agent-mode.md`.

### P1. Thread registry, archive, resume, new, quick prompt

- `src/backend/history/persistence/sqlite.zig`: `thread` table,
  `user_version` 6; `history.Service.recordThread`, `updateThreadStatus`,
  `closeThread`, `archiveThread`, `renameThread`, `queryThreads`.
- `src/backend/agent/tracker.zig`: publish registry events on session
  reference, status transition, title change, blocked reason and exit; the
  tracker calls the service, it does not write SQL.
- `src/backend/runtime/application/git_status.zig`: common-dir probe and the
  `project_key` cache.
- `src/core/schema`: `query_threads`, `thread_list`, `archive_thread`,
  `rename_thread`, `resume_thread`, `create_thread`; fingerprint bump and
  corpus.
- Runtime commands: `resume_thread` reuses the checkpoint restore launch;
  `create_thread` composes workspace, tab and pane creation in one
  transaction under ADR 0001, with the manifest gaining an allowlisted
  `launch` argv for the three built-ins.
- CLI: `telar thread list|get|archive|unarchive|rename|resume|fork|new|import`.
- Manifests: `launch`, `options` and `live` for the three built-ins in
  `src/core/agent_manifest.zig`; `client.agent_mode.defaults`; option
  validation at config load; `create_thread` carries at most 8 validated
  `(key, value)` pairs and the runtime builds the argv.
- Client: projects from the registry, ARCHIVED section, the composer widget
  (`input/text_area.zig`, `widgets/agent_mode/composer.zig`) as K4 with the
  K3 form under 120 columns, its hybrid KGP layer (`graphics/composer.zig`:
  frame, chips, ring, thumbnails, approval band) on the toast pipeline, `p`
  to focus it on a running thread, `ctrl+e` to hand the draft to `$EDITOR`
  in a transient command tab, live option changes through the manifest's
  slash command with pending state until the reader confirms.
- Tests: registry transitions, duplicate references, stale generations,
  project key for worktrees, resume allowlist, page bounds, corpus, option
  validation (enumerated, free text, option-looking values rejected), argv
  construction per built-in, composer refused while blocked, editor tab
  round trip, pending model confirmation from a transcript fixture.

### P2. Conversation view

- `src/backend/agent/session_readers/{claude,codex,pi}.zig`: incremental
  record readers with the line cap and skip policy, normalizing to
  `ThreadItem`; `session_file.Watches` extended to follow items, not only
  titles.
- `thread_item` table with FTS over user items; `query_thread_items`,
  `thread_items`, `read_thread_item`, `thread_item_text`.
- `src/frontend/widgets/agent_mode/conversation.zig` with the rendering
  rules and keys above, including the outline; bounded page storage
  allocated once at startup like the history browser.
- Tests: readers against fixtures split at every byte boundary, oversized
  lines, compaction records, tool pairing out of order, Codex rollouts with
  interleaved `event_msg`, Pi branches; widget snapshot; paging under
  concurrent appends; outline jumps.

### P2r. Rasterized composer editor

- `graphics/text_layout.zig`: HarfBuzz shaping over the embedded faces,
  line breaking to a pixel width, cluster-to-pixel and pixel-to-cluster
  maps; `graphics/composer_raster.zig`: one image per visual line, caret
  and selection as placements, raster keys by line content and width.
- Second embedded proportional face (OFL) and its attribution in
  `src/frontend/assets/README.md`.
- `text_area` gains a renderer-independent model API; the cell renderer of
  P1 stays wired as the fallback; transport and KGP capability select the
  renderer per client.
- Benchmark `frontend.composer.echo` in `zig build bench`: one-line raster
  plus encode plus placement; the gate is p99 under 16.7 ms locally.
- Invariants: record the exception and the fallback rule.
- Tests: layout against fixtures (wrapping, clusters, RTL-free assumption
  stated), caret and selection mapping, fallback when KGP is lost
  mid-session, remote client never receives the raster editor, draft kept
  across the fallback.

### P3. Changes view

- Git observer file list; `changes_list` in the workspace snapshot or a
  dedicated query; widget; transient diff tab through `command_tab`;
  `client.agent_mode.diff_command`.
- Later: per-file notes composed into one prompt.

### P4. Views, search, look

- `client.agent_mode.views` as validated data; global `ctrl+alt+` chords;
  attention count in the host title; opencode reader; `telar thread
  search`; narrow-terminal refinements; optional Codex app-server client for
  live item streaming without file tailing.
- The chosen look: C's KGP chrome (cards, bubbles, gutters, thumbnails)
  over the cell widgets, reusing the toast raster pipeline and the hybrid
  sidebar assets; D as a separate spike on the conversation view if C is
  judged insufficient.
- What multiplexer mode gets for free from the registry: attention badges
  on tabs and workspaces (herdr's rollup), `thread_next_attention` bound
  there too, and archived threads in the goto picker.

## Open decisions

None block implementation. Two defaults are settled here unless the
implementation finds a reason not to:

1. Built-in options: claude exposes model, effort and permission mode; codex
   exposes model, reasoning effort, sandbox and approval; pi exposes
   provider, model and thinking. Anything else is one manifest entry.
2. A screen-only `blocked` shows no reason text; only hook reports do.


## Appendix A. Keymap

Every binding below is a default in `config/default_bindings.zig` and
rebindable through `client.keybindings` like every other action. Actions are
stable names in `src/frontend/input/action.zig`.

Multiplexer mode and agent mode:

| Keys | Action | Notes |
| --- | --- | --- |
| `prefix` `a` | `toggle_agent_mode` | Client state; travels in `update_client_layout`. |
| `prefix` `g` | `goto_picker` | Gains threads, archived included, in P1. |

Agent mode, browse focus (the browse owner consumes these before the pane):

| Keys | Action | Notes |
| --- | --- | --- |
| `j` `k` | `thread_next`, `thread_prev` | Inside the inbox; wraps across sections. |
| `Enter` | `agent_mode_open` | Opens the selected thread in the view; a second `Enter` or `i` enters interact. |
| `i` | `agent_mode_interact` | |
| `Tab` | `agent_mode_view { next }` | Cycles terminal, conversation, changes. |
| `h` `l` | `agent_mode_column { prev, next }` | Projects, inbox, view. |
| `1`…`9` | `agent_mode_select_project { u8 }` | |
| `g` | `thread_next_attention` | Next thread in NEEDS YOU, then DONE. |
| `/` | `agent_mode_filter` | Name-prompt editor; prefixes `@` needs you, `!` working, `#` ready. |
| `n` | `thread_new` | Opens the composer in new-thread form. |
| `p` | `composer_focus` | Focuses the composer on the selected thread. |
| `r` | `thread_rename` | telar title only. |
| `a` | `thread_archive` | Asks when the thread is live. |
| `R` | `thread_resume` | Archived threads. |
| `f` | `thread_fork` | Manifest fork flag; relation `fork`. |
| `x` | `thread_kill` | Asks; closes the pane, thread stays unarchived. |
| `z` | `agent_mode_zoom` | View column over the other two. |
| `Esc` | leaves filter, zoom or the composer, in that order | |

Agent mode, interact focus (everything else goes to the pane):

| Keys | Action | Notes |
| --- | --- | --- |
| `prefix` `Esc` | `agent_mode_browse` | Back to browse. |
| `ctrl+alt+j` `ctrl+alt+k` | `thread_next`, `thread_prev` | Without leaving interact; global chords. |

Conversation view (browse focus, view = conversation):

| Keys | Action |
| --- | --- |
| `j` `k` | scroll one line |
| `{` `}` | previous / next user prompt |
| `[` `]` | previous / next tool call |
| `Enter` | expand or collapse the tool call under the cursor (`read_thread_item`) |
| `o` | outline on / off; `Enter` jumps |
| `/` | search the loaded page |
| `t` | show / hide thinking |
| `y` | copy the message under the cursor through OSC 52 |
| `G` | jump to the tail and follow it |
| `gg` | top |
| `Tab` | switch to the terminal of the same thread |

Composer (focused):

| Keys | Action |
| --- | --- |
| `Enter` | send (`send_pane_text`, prompt mode) or create |
| `alt+Enter` | newline (Shift+Enter needs the kitty keyboard protocol and is accepted when reported) |
| `Tab` / `shift+Tab` | next / previous field in the settings column (K4) |
| `ctrl+m` `ctrl+r` `ctrl+p` | open the model, effort, mode pickers (K3 uses `/model`, `/effort`, `/mode`) |
| `ctrl+e` | edit the draft in `$EDITOR` in a transient command tab; the text comes back on exit |
| `ctrl+x` | stop: sends the manifest's interrupt key |
| `up` `down` on the first / last line | prompt history, 32 entries per thread |
| `y` `a` `n` `i` while blocked with hook authority | approve once, approve for session, decline, answer in the terminal |
| `Esc` | back to browse, draft kept |

## Appendix B. Wire messages

All new messages follow `src/core/schema` conventions: fixed tags, bounded
fields, fingerprint bump, corpus entry in `schema_contract_test.zig`.
Byte caps are maxima; every string is length-prefixed and UTF-8 validated.

| Message | Direction | Fields | Bounds |
| --- | --- | --- | --- |
| `update_client_layout` (extended) | client → runtime | `+ mode: u8 { multiplexer=0, agent=1 }`, `+ agent_mode: { focus: u8, project_key_hash: u64, selected_thread: ?ThreadKey, view: u8 }` | existing message, new fields |
| `query_threads` | client → runtime | `request_id`, `project_key: ?[]u8 ≤ 1 KiB`, `statuses: bitset`, `archived: enum { exclude, include, only }`, `text ≤ 256 B`, `cursor: u64`, `limit ≤ 100` | one page |
| `thread_list` | runtime → client | `request_id`, `entries[≤100]`, `next_cursor: u64` | entry below |
| `ThreadEntry` | | `id: u64`, `provider: AgentProvider`, `provider_name ≤ 32 B`, `session_ref ≤ 64 B`, `project_key_hash`, `project_path ≤ 1 KiB`, `branch ≤ 64 B`, `title ≤ 96 B`, `title_source`, `status: AgentStatus`, `blocked_reason ≤ 256 B`, `model ≤ 64 B`, `started_at_ms`, `last_change_ms`, `archived: bool`, `pane: ?{pane_id, generation}`, `parent: ?u64`, `relation: u8` | |
| `archive_thread` / `unarchive_thread` | client → runtime | `thread_id` | answered by `request_completed` or `request_failed` |
| `rename_thread` | client → runtime | `thread_id`, `title ≤ 96 B` | |
| `resume_thread` | client → runtime | `thread_id`, `workspace: ?WorkspaceId` | allowlisted argv reconstructed in the runtime |
| `fork_thread` | client → runtime | `thread_id` | manifest fork flag; new thread with relation `fork` |
| `create_thread` | client → runtime | `project_path ≤ 1 KiB`, `provider`, `options[≤8] { key ≤ 32 B, value ≤ 64 B }`, `worktree: ?{ branch ≤ 64 B, base ≤ 64 B }`, `prompt ≤ 8 KiB` | one transaction under ADR 0001 |
| `thread_created` | runtime → client | `request_id`, `thread_id`, `workspace_id`, `tab_id`, `pane_id`, `generation` | |
| `query_thread_items` | client → runtime | `thread_id`, `cursor: u64`, `limit ≤ 100`, `direction: u8` | |
| `thread_items` | runtime → client | `thread_id`, `items[≤100]`, `next_cursor`, `prev_cursor`, `live: bool` | item below |
| `ThreadItem` | | `seq: u64`, `kind: u8 { user, assistant, thought, tool_call, tool_result, compaction, title, subagent, system }`, `tool_id ≤ 64 B`, `tool_kind: u8 { read, edit, delete, move, search, execute, think, fetch, other }`, `status: u8 { pending, in_progress, completed, failed }`, `preview ≤ 512 B`, `byte_len: u32`, `ts_ms`, `tokens: ?u32` | |
| `read_thread_item` | client → runtime | `thread_id`, `seq` | |
| `thread_item_text` | runtime → client | `thread_id`, `seq`, `text ≤ 64 KiB`, `truncated: bool` | late-bound like `pane_text` |
| `set_thread_option` | client → runtime | `thread_id`, `key ≤ 32 B`, `value ≤ 64 B` | runtime types the manifest's live command through `send_pane_text`; refused while blocked |
| `thread_option_confirmed` | runtime → client | `thread_id`, `key`, `value` | emitted when the reader sees the change |

`send_pane_text` keeps its shape; the composer uses `mode = prompt`.

## Appendix C. Registry DDL

`user_version` moves from 5 to 6. Migrations are additive; there is no
downgrade path, like the existing history migrations.

```sql
CREATE TABLE thread (
  id INTEGER PRIMARY KEY,
  provider INTEGER NOT NULL,
  session_ref TEXT NOT NULL,
  project_key TEXT NOT NULL,
  project_path TEXT NOT NULL,
  cwd TEXT NOT NULL,
  branch TEXT,
  title_agent TEXT,
  title_telar TEXT,
  title_source INTEGER NOT NULL DEFAULT 0,
  transcript_path TEXT,
  transcript_kind INTEGER,
  started_at_ms INTEGER NOT NULL,
  ended_at_ms INTEGER,
  last_status INTEGER NOT NULL,
  last_change_ms INTEGER NOT NULL,
  blocked_reason TEXT,
  model TEXT,
  options TEXT,               -- JSON array of [key, value], validated on write
  archived INTEGER NOT NULL DEFAULT 0,
  pane_id INTEGER,
  pane_generation INTEGER,
  parent_id INTEGER REFERENCES thread(id),
  relation INTEGER NOT NULL DEFAULT 0,  -- 0 none, 1 resume, 2 fork, 3 subagent, 4 handoff
  UNIQUE (provider, session_ref)
);
CREATE INDEX thread_project ON thread (project_key, archived, last_change_ms DESC);
CREATE INDEX thread_status ON thread (last_status, last_change_ms DESC);

CREATE TABLE thread_item (
  thread_id INTEGER NOT NULL REFERENCES thread(id),
  seq INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  tool_id TEXT,
  tool_kind INTEGER,
  status INTEGER,
  preview TEXT NOT NULL,      -- <= 512 bytes, secrets filtered like commands
  file_offset INTEGER NOT NULL,
  byte_len INTEGER NOT NULL,
  ts_ms INTEGER,
  tokens INTEGER,
  PRIMARY KEY (thread_id, seq)
);
CREATE VIRTUAL TABLE thread_item_fts USING fts5(preview, content='thread_item', content_rowid='rowid');
-- Only kind = user rows are inserted into the FTS index (trigger with a WHERE).
```

Row bounds enforced before the worker writes: `session_ref` 64 bytes,
`project_path`, `cwd` and `transcript_path` 1 KiB, titles 96 bytes,
`blocked_reason` 256 bytes, `model` 64 bytes, `options` 8 pairs.

## Appendix D. Manifest additions

`runtime.agents` entries gain three optional fields. `launch` is accepted
only for the shipped names (`claude`, `codex`, `pi`), like `resume`; a
configured agent may extend `options[].values` and `defaults` but may not
add flags.

```lua
{
  name = "claude",
  launch = { argv = { "claude" } },
  options = {
    { key = "model", label = "model", kind = "choice",
      values = { "opus", "sonnet", "haiku" }, free = true,   -- free: any 64-byte token without a leading '-'
      flag = "--model", live = "/model {value}" },
    { key = "effort", label = "effort", kind = "choice",
      values = { "low", "medium", "high", "xhigh", "max" }, flag = "--effort" },
    { key = "mode", label = "permissions", kind = "choice",
      values = { "default", "acceptEdits", "plan", "bypassPermissions" }, flag = "--permission-mode" },
  },
  title_flag = "-n",            -- the thread title is passed at launch when known
  interrupt = "esc",            -- key sent by ctrl+x
  fork_flag = "--fork-session", -- used by thread_fork together with resume
}
```

Codex: `launch = { argv = { "codex" } }`, options `model` (`-m`), `effort`
(`-c model_reasoning_effort="{value}"` as one argv element), `sandbox`
(`-s`), `approval` (`-a`), `profile` (`-p`, free text); live `/model {value}`;
interrupt `esc`. Pi: `launch = { argv = { "pi" } }`, options `provider`
(`--provider`, free), `model` (`--model`, free), `thinking` (`--thinking`,
values off, minimal, low, medium, high, xhigh, max); live `/model`;
interrupt `esc`. Flags verified against `--help` on 2026-09-06 for claude
2.1.263, codex 0.153.4 and pi 0.85.1.

Client defaults:

```lua
client = {
  agent_mode = {
    defaults = { claude = { model = "opus", effort = "high" }, codex = { effort = "high" } },
    diff_command = { "git", "diff", "--" },
    views = { { name = "focus", filter = { status = { "blocked", "done" } }, sort = { "attention", "last_change" } } },
  },
}
```

Validation at config load: `key` and `values[]` are 1..64 bytes of
`[A-Za-z0-9._:/@+-]`, never starting with `-`; at most 16 options per
manifest and 16 values per option; `flag` must start with `-` and contain
no spaces; `live` is a template with exactly one `{value}`.

## Appendix E. Composer specification

Model (`src/frontend/input/text_area.zig`): a fixed 8 KiB UTF-8 buffer, a
cursor and an anchor as byte offsets on grapheme boundaries, `insert`,
`deleteBackward`, `deleteForward`, `moveLeft/Right/Up/Down/Home/End`,
`selectAll`, `lineCount(width)`, `visualLines(width)` yielding byte ranges,
a 32-entry ring of previous prompts per thread, `takeText`. No allocation
after init; wrapping is computed per render from the width.

State (`src/frontend/client/model/composer.zig`):

```text
Composer {
  form: new_thread | thread(ThreadKey),
  provider: AgentProvider,             -- locked in form thread
  options: [8]{ key, value, pending: bool },
  project: ?ProjectKey, worktree: none | { branch, base },
  text: text_area.Model,
  history_cursor: ?u8,
  focus: editor | field(u8),
  layout: k4 | k3,                       -- from the view column width
  renderer: cells | raster,              -- from KGP capability, transport and the gate
}
```

Widget (`src/frontend/widgets/agent_mode/composer.zig`): K4 geometry is
the view column minus one border; the settings column is 25 cells wide and
holds, in order, provider, model, effort, mode, context, and the action row;
in new-thread form it holds project, worktree, base, branch, provider,
options and create. Below 120 columns the K3 form draws the editor, the
command popup and the status line. Mockups `07`, `08`, `11` to `14` are
normative for glyphs and columns.

Actions: `Enter` → `send_pane_text { mode = prompt }` after any pending
`set_thread_option`; refused with a footer message when the thread is
`blocked`; while `working` the action label reads `queue`. `ctrl+x` sends
the manifest's interrupt key. In new-thread form `Enter` → `create_thread`.

Renderers: the cell renderer draws into the buffer; the raster renderer
(P2r) draws one image per visual line with the caret and selection as
placements and is selected only when KGP is negotiated, the transport is
local or shared memory, and the echo gate has not tripped in this session.

Drafts: per thread, in the client, 8 KiB each, at most 16; lost with the
client (T3 keeps them in localStorage; telar's equivalent is a later
addition to the client layout replica if the loss annoys).

## Appendix F. KGP layer of agent mode

Hybrid rules apply everywhere in agent mode: cells own text, cursor,
selection, hit targets; KGP images sit below cells (negative z-index, as
the sidebar card) except thumbnails, which sit above their reserved cells.
Every image has a raster key; a change of key re-rasters, anything else is
a placement update. Media failure deletes every agent-mode placement and
leaves the cell chrome complete.

| Image | Key | Size | Where |
| --- | --- | --- | --- |
| Composer frame | width, height, theme, state (normal, blocked, pending) | view column × composer rows | under the composer |
| Option chip | label, value, provider mark, pending, theme, cell size | 23 × 1 cells | settings column rows |
| Context ring | percent (rounded to 2), theme, cell size | 2 × 1 cells | context row |
| Thumbnail | image identity, cell size | 8 × 3 cells | under the editor |
| Approval band | theme | editor width × 3 rows | blocked state |
| Model popover border | modal geometry | modal | as the goto picker's KGP border |
| Thread card (inbox) | selected, status, theme, width | inbox width × 1 row | under the selected row, as the sidebar card |
| Message bubble (conversation, P4) | role, width, theme | message width × rows | under each message |
| Tool gutter (conversation, P4) | kind, status, theme | 1 × rows | left of tool lines |

Per-frame budget stays at 256 KiB encoded; the composer's set fits in one
frame at 60 Hz on a 1400×900 terminal (measured sizes in the phase's
benchmark). The raster editor of P2r adds one image per visual line (≤ 64)
and is subject to the gate.

## Appendix G. Invariants exception (text for `docs/engineering-invariants.md`)

Add under "Three paths › Interactive", after the Lua binding rules:

> The agent-mode composer may render its own editor as media-path images
> (ADR 0011). This is the only place where a keystroke's visible echo
> crosses the media path. The composer model still commits on the
> interactive path with no allocation; only the raster and its transfer are
> media work. A one-line echo must present within one pacer interval at
> p99 on the local transport; a session that misses the gate switches the
> composer to its cell renderer for the rest of the session and reports the
> switch in telemetry. Remote clients never use the raster renderer. The
> pane's own path is unaffected.

## Appendix H. Session reader normalization

| Provider record | Item kind | Preview | Notes |
| --- | --- | --- | --- |
| Claude `user` with text | `user` | text | anchors; `isCompactSummary` becomes `compaction` |
| Claude `assistant` text block | `assistant` | text | `usage` → tokens; `message.model` → thread `model` |
| Claude `assistant` thinking block | `thought` | first 512 B | hidden by default |
| Claude `assistant` tool_use | `tool_call` | name + summarized input | `tool_kind` from name: Bash → execute, Read → read, Edit/Write → edit, Grep/Glob → search, WebFetch → fetch, Agent → other + `subagent` link |
| Claude `user` tool_result | `tool_result` | first 512 B | paired by `tool_use_id`; exit code parsed from Bash results when present |
| Claude `system` compact_boundary | `compaction` | trigger, pre tokens | |
| Claude `ai-title`, `custom-title` | `title` | title | feeds the thread title with the existing precedence |
| Codex `response_item/message` | `user` or `assistant` by role | text | developer role → `system` |
| Codex `response_item/reasoning` | `thought` | first 512 B | |
| Codex `custom_tool_call` / `_output` | `tool_call` / `tool_result` | name + args / output | paired by `call_id` |
| Codex `turn_context` | (updates thread `model`) | | |
| Codex `compacted` | `compaction` | | |
| Codex `event_msg/task_started|complete` | (status evidence only) | | |
| Pi `message` role user / assistant | `user` / `assistant` | text | `parentId` tree: the reader follows the branch the session header points to |
| Pi `message` role toolResult / bashExecution | `tool_result` | output | paired by `toolCallId` |
| Pi `model_change` | (updates thread `model`) | | |
| Pi `session_info` | `title` | name | |
| any line over 256 KiB | the kind inferred from its prefix, preview `[N KB omitted]` | | never parsed |

Readers keep `file_offset` per item and a per-file `last_offset`; a file
shorter than `last_offset` is re-read from zero (rotation or rewrite). One
probe in flight per runtime, one second cadence for followed files, at most
16 followed files.

## Sources

telar: `docs/capabilities.md`, `docs/sidebar.md`, `docs/kitty-graphics.md`,
`docs/flows/agent-*.md`, `docs/plans/herdr-adoption.md`,
`docs/plans/proxy-tap.md`, `docs/plans/atuin-ai-adoption.md`,
`src/frontend/widgets/{sidebar,composition}.zig`,
`src/frontend/graphics/{rasterizer,toast,kitty_sidebar,kitty_codec}.zig`.
herdr: local checkout `~/sandbox/herdr` (website docs `concepts`,
`agent-automation`, `socket-api` agent view queries, changelog 0.7.5, blog
"Coding agents are becoming runtimes").
Graphical tools: T3 Code glossary and issue #442; Conductor docs and HN
44594584; Vibe Kanban docs, shutdown post, issue #765; Superset changelog and
HN 48236770, 46368739; Xum keybinds; Sculptor; Emdash docs and HN 47140322;
Multica; Kilo Agent Manager; Cursor 3.0 changelog and forum thread 168982;
Zed parallel agents and discussion #42381; Claude Code Desktop docs and issue
#36885; Codex app docs and issue #26875; Warp agent management; Ghostty 1.3,
Kitty, WezTerm changelogs; cmux issue #2576.
Terminal-native tools: herdr docs and HN 48714802, 49104999, issues #3657,
#3653, #3671; Claude Squad issues #312, #325, #266; ccmanager; agent-deck;
cmux notifications docs and issues #11953, #11975; Gas Town docs and the
"good, bad, ugly" write-up; openai/symphony SPEC; opencode keybinds and issue
#24451; Amp handoff and thread map; Backlog.md; beads; recon,
tmux-agent-sidebar, tmux-agent-status, tmux-agent-indicator, zellaude,
wezterm-agent-deck, wezterm-agent-cards; lazygit, k9s, helix, gh-dash, yazi
and aerc keymaps.
Formats and protocols: Claude Code sessions, hooks, headless and interactive
docs; ccrider schema notes; claude-code #32175; Codex hooks, app-server and
config docs, issues #15943, #28503; Pi session, rpc and extensions docs;
opencode server and SDK docs; Gemini CLI session and hooks docs; Amp threads
docs; claude-trace and claude-tap; ACP protocol docs.
