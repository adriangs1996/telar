# Sidebar integration contract

The runtime publishes bounded, self-contained agent snapshots assembled from
lifecycle hooks, the foreground process, terminal-screen hints, and canonical
workspace state.
Detection replaces the client snapshot; it does not own layout, focus,
scrolling, hit targets or drawing.

## Ownership

The runtime owns agent truth and publishes stable `(pane_id, generation)` task
identity. `ClientModel` keeps one disposable `agents.Snapshot` replica. The
window's `SidebarState` keeps only visible interaction state: scroll
positions and the attention order of the current snapshot. The runtime retains the selected tab, pane focus, split trees,
sidebar geometry and workspace-list collapse for reconnecting clients; hover
and sidebar scroll still die with the client. None of this alters a runtime
task or agent.

Each entry carries workspace and tab labels, one-based pane position, a reduced
cwd label, and a session title in addition to provider and status. The runtime
resolves all of them against the same `(pane_id, generation)` immediately
before encoding. Workspace rename, tab rename, cwd changes, and pane topology
advance the agent revision.

Three fields describe what the agent wants from the person:

| Field | Bound | Source |
| --- | --- | --- |
| `blocked_reason` | `none`, `permission`, `question`, `plan`, `other`; `none` unless the status is `blocked` | The lifecycle report when its hook names one (Claude Code `permission_prompt`, elicitation notifications, `AskUserQuestion` and `ExitPlanMode` tool starts; Codex `PermissionRequest`; Pi dialogs; OpenCode `permission.asked` and `question.asked`). Cursor Agent has no hook for its approvals, so its approval and plan-review screens are `other`. Without a report, a blocked agent whose last proxy response closed on a tool request while no exchange is open is `permission`; any other blocked state is `other`. |
| `last_event` | one control-free UTF-8 line of at most 96 bytes | The event line of the lifecycle report the projection follows: the prompt text while blocked, the last tool call (`» Edit src/client/bars/Output.zig`) while working, the first line of the final assistant message when done. Empty while any other evidence decides. |
| `status_age_s` | `u32` seconds | The runtime clock at encode time minus the last projected status change. It is never part of the revision; the client adds the time since the snapshot arrived. |

A changed reason or event line advances the agent revision like a label. The
reason and the line are presentation only: they choose an icon and a chip and
never authorize an answer on the agent's behalf.

## Attention order

One comparator orders agents for every surface: the sidebar list, "next
agent that needs me" and toast order. Groups from first to last: needs input (`blocked`, `failed`), working,
ready-unseen (`done`), idle (`ready`), `unknown`. Inside a group the smallest
`status_age_s` comes first; equal ages fall back to pane id and generation so
the order is stable across revisions. It is pure and allocation-free.

`agent_snapshot.applyAgentSnapshot` is the protocol adapter. It maps borrowed
wire entries to `AgentInput` values. The model's `agent_snapshot.reconcile`
owns the transaction, while `agents.Snapshot.replace` performs atomic bounded
storage. After the commit, `applyAgentSnapshot` synchronizes pane attachments,
publishes actionable alerts and synchronizes the sidebar animation, in that
order. Replacement:

- rejects revisions older than or equal to the current revision;
- rejects duplicate `(id, generation)` task keys;
- copies all strings into fixed-capacity storage;
- accepts at most 64 tasks;
- allocates nothing.

Task keys carry a generation so a delayed action cannot target a new task that
reused an old numeric ID. A task may carry a `pane_id`; selecting it then uses
`agent_navigation.planMove`, which returns either local tab and pane
focus or a runtime pane handoff. Input code never reads replica storage.

## Session titles

Every detected agent starts with a local placeholder such as `New Codex
session`. Title generation is disabled unless `runtime.agent_descriptions` is
configured in Lua. When enabled, Telar captures at most 4096 bytes from the
first submitted user request. When the agent first moves to `working`, Telar
runs the configured argv command in parallel and outside the interactive path.
The request is written to stdin and never appears in process arguments or
history storage.

The sidebar session title
remains separate from the tab label and survives GUI detach and reconnect.

The queue admits eight pending jobs and one active child. Output is capped at
512 bytes, must normalize to one control-free UTF-8 line of at most 96 bytes,
and is guarded by a deadline. Missing executables, queue pressure, timeout,
invalid output, stale pane generations, and stale session IDs retain the
placeholder with a deterministic failure state. There are no automatic
retries. A manual title has higher authority than a generated completion.

A name the user gives the session inside the agent (`/name` in Pi, `/rename`
in Claude Code and Codex) reaches the runtime through the agent's hooks or the
file it records its session in as a
title with source `agent`. It
replaces a generated or manual title, is checkpointed like a manual one, and
clearing the name inside the agent returns the row to its placeholder unless a
manual title was set afterwards.

Only the validated title, source, and state are persisted by `session_id` in
the history database. Prompt bytes are cleared when the job starts or is
discarded.

## What survives a restart

The session checkpoint keeps, for each pane whose agent it resumes, the
session, the title a person or the agent gave it, and the agent's final
message, whole. When the runtime starts again and sees that agent in its
pane, the agent takes them back before its hooks report anything: its card
shows what it last said while it rests, and the message it reports next
replaces it. A checkpoint written before the final message was kept restores
none.

The last event and the plan are not kept. The event line is projected from
evidence that expires, and a plan belongs to the turn the restart ended.

## Focus projection

The focused pane is the sole source of truth for the agent highlight. Sidebar
composition projects the active tab's focused pane through the current agent
snapshot and highlights the matching agent. It highlights no agent when the
focused pane has no matching agent.

Clicking an agent is a navigation action, not a second kind of focus. It may
switch workspace or tab before focusing the agent's pane. The highlight follows
only after pane focus changes. Pane navigation and workspace or tab changes
recompute the same projection, so the sidebar never preserves an independent
agent selection. A cross-workspace handoff restores the target tab's pane order
before applying focus, so navigation does not renumber the selected pane. When
the runtime still reports the same pane set, the client restores its bookmarked
split tree, including split axes and ratios. If the pane set changed while the
workspace was hidden, the client falls back to canonical pane order before
applying focus. Every successful transition, including workspace creation,
bookmarks the workspace being left before destroying its client-side tab
models.

The runtime pane position remains immutable in `agents.Snapshot`. When the
active client layout has a different local display order, the sidebar derives
that pane index while rendering. No widget rewrites the runtime replica.

## Machines

The top bar names the machine the window shows right after the sidebar toggle,
as one control: the machine's avatar (its color and the first character of its
label) with a dot for its link, its label and a chevron. A yellow dot before
the chevron says an agent on another machine waits on the person. The control
is there with one machine too.

Clicking it opens the machine menu under it: every machine of the window in a
fixed order, one row each, the one the window shows marked. A row shows the
avatar with its link dot, the label over a status line and, on the right, a
stack of its agents that work or wait on the person, in attention order, at
most three. The row of the machine the window shows keeps only their count,
since the sidebar lists them. The status line reads `Offline`, `No active
agents` or the number of agents that work or wait, in yellow when one of them
waits on the person. The cards are the tab strip's: the same tiles, provider
colors and resting poses. A row has no focused pane, so a waiting agent's card
is tinted even when it is in front. Clicking a row switches to that machine and
closes the menu. The last row, `Add or manage machines…`, opens the machine
picker, where a machine is added, set up, enabled or disabled.

The sidebar lists no machine. Its section headers (`Agents`, `Processes`) read
their name in capitals at the small size, after a line icon in the cards' mark
column and before their count. The icons are Lucide's (`assets/icons`, ISC),
rasterized from SVG and tinted with `subtext0`. A hairline halves the gap
between two sections.

The agent list holds every agent and tracked command of the active machine,
and only the agents that wait on the person (`blocked`, `failed`) from the
others: their working agents are the stack of their row in the machine menu,
and a waiting agent keeps a card because the stack does not show what it asks
and clicking the card goes straight to its pane. Cards from the active machine
name only their workspace; a waiting agent from another machine prefixes it
with `machine · `.

## Workspaces

After the machine, the top bar holds the workspace track: one segmented control
with every workspace of the machine in the runtime's order, each segment the
workspace's mark (a tile in a hue its name picks from the palette's accents,
holding its initial) and its name. The segment of the workspace in front is
filled and ringed. A workspace with an agent that waits on the person shows a
dot in that state's color after its name, or on its mark's corner when the
segment shows no name.
Clicking a segment switches to its workspace, and the tabs beside the track
are then that workspace's. Hovering a segment shows its name and its path.

The track leaves the tabs their room. One or two workspaces show their names
when the bar has room for them, each segment as wide as its name in the heavier
weight, so choosing one moves neither. With three or more, or without that
room, the workspace in front keeps its name and the others keep only their
mark. Short of that too,
the marks that do not fit hide, the row moves just enough to hold the workspace
in front, and the control at the end of the track counts the hidden ones as
`+N`.

That control, a chevron while nothing is hidden, opens the workspace menu under
the track: every workspace in the track's order, each with its mark, its name,
its path (or what its worktrees' agents do) and its branch, a dot after the
branch while it has changes, and `! N` in the state's color while agents wait.
The workspace in front is marked. Typing filters the rows by name, Up and Down
move the selection, Enter chooses it and Escape closes the menu. The last row,
`New workspace…`, opens the form that creates one.

## Processes

The runtime publishes `PaneList`, every live pane with its id, generation,
tab location, foreground name (at most 48 bytes, `shell` when unknown), the
seconds since that process took the terminal, up to four TCP ports its
process group listens on (the lowest, ascending), and `shell`, set while the
pane's root process holds the terminal and still runs a shell (`bash`,
`zsh`, `ksh`, `sh`, `dash` or `fish`). A command pane execs its program in
place of the launching shell, so it is not a shell. The list holds at most
256 entries, the runtime's pane capacity. Its revision is the pane revision,
which advances when a pane joins or leaves the list or its foreground group,
name, shell state or ports change, plus the workspace revision, so tab moves
resend it.

For every pane of that list the runtime also publishes `PaneFacts` (since
schema `cqp00013`), one message per pane:

| Field | Bound | Source |
| --- | --- | --- |
| `command_state` | `none`, `running`, `finished` | The newest command of the pane's integrated shell, from its signed marks. `none` for a pane without an integrated shell, and until its shell runs one. An `ssh` that hosts a remote shell is `running` until it returns. |
| `command`, `command_truncated` | first line, at most 160 bytes | The text the shell ran, as its command block reads it. `command_truncated` is set when the command had more lines or a longer first one. |
| `exit_code` | optional `i32` | The status a finished command reported; none while it runs and for a command a new prompt interrupted. |
| `duration_ms` | `u32` | How long a finished command ran; 0 otherwise. |
| `directory` | at most 48 bytes | The pane's working directory as an agent's `cwd_label` writes it, the home as `~`; empty when the path holds what display text does not take. |
| `in_workspace` | flag | The directory is the pane's workspace's, or lies in it. |
| `document` | at most 160 bytes | What an editor pane titles itself: the file its focused window shows, with `+` while it has unwritten changes. Empty for every other pane, whose title is its program's to set. |
| `branch`, `dirty` | at most 96 bytes, flag | The branch of the repository the integrated shell works in, read after each command, and whether it has staged, unstaged or conflicted changes; empty outside a repository and for a pane without an integrated shell. |

A pane's facts follow the list that names it and are sent again, for that
pane alone, when a command starts or ends, its directory changes, its
repository reads differently or its editor shows another file. A command or a branch that is not display text
is left out like the directory, so one pane never ends the delivery to every
client that lists the panes. The command is kept apart from the pane's
command blocks, so it stays after `clear` drops the rows a block was anchored
to. A shell builtin counts like any command: the marks are the shell's, not
the foreground process's. A runtime older than `cqp00013` sends none, and
every pane then shows as one that ran nothing.

The window keeps the facts with the pane in its list replica; a newer list
that still names the pane leaves them, and a list from a runtime that
replaced the previous one drops them. A process card reads `commandLine`,
`commandState` (`none`, `running`, `finished`), `commandTruncated`,
`exitCode` (absent unless a finished command reported one),
`commandDuration` (`12s`, `3m`, as the ages are written), `document`, `cwd`,
`branch` and `dirty`. When a pane's shell read no repository and the pane works in
its workspace, `branch` and `dirty` are its workspace's. An agent card
reads `tab` and `cwd` from its snapshot entry and `branch` and `dirty` from
its workspace.

The observation worker reads the ports when the foreground changes and every
2 seconds while a program holds the terminal; idle shells and agent panes
are not read. On
macOS it walks the group's socket descriptors through `libproc`. On Linux it
matches the inodes of the user's listening sockets in `/proc/net/tcp` and
`tcp6` against the group's `/proc/PID/fd` links. A program that detaches into
another process group is not counted.

Under `Processes`, the sidebar lists every pane of the active machine that no
agent snapshot entry holds by `(pane_id, generation)`, so agents and processes
together cover every pane of that machine; the other machines are the rows of
the machine menu. Programs come before idle shells, and the newest foreground
comes first inside each group.

A process card has the three rows of an agent card. The first names the
program, after its mark (a terminal glyph when the program is unknown), and
says on the right `running` or, for an idle shell, `idle`, with the foreground
age, which advances locally between revisions; an idle shell's mark and name
recede. The second is the command the pane's shell runs or ran last, and what
that left closes it on the right: the ports the program listens on while it
serves, each as the terminal writes it and in the terminal's face (`:3000`,
`:3000 :9229`, then `+N` for the rest), a green mark and how long the command
took when it ended well (`✓ 12s`), a red mark and its exit status when it
failed (`✕ 1`). An editor pane has no command: its second row is the file its
focused window shows. A pane whose shell ran nothing reads `No commands yet`,
and any other program without a command of the shell reads `No command`. The third says
where: the workspace, then the pane's directory, and on the right the branch
with a dot while it has changes. Clicking a card visits its pane the way an
agent card does; a process card has no peek.

## Rendering boundary

The window draws the sidebar in device pixels. The terminal client's cell
sidebar and its Kitty graphics layer left with it.

The window draws cards in device pixels inside the sidebar band. Text uses the `title`, `small`,
`small` line boxes. The title is body-sized without the pane header's height cap. Insets are 8 horizontal and 8 vertical logical pixels,
with 4 logical pixels before the second row and 2 before the third. Card spacing
is 3, sidebar margins 8, radius 8 and provider symbols 14 logical pixels.
These lengths follow the chrome's display/font ratio before being rounded:
they are written for a 14-pixel font and grow with `font.size` and
`chrome.scale` as the chrome text does, so a mark keeps its size beside its
title. The sidebar margin follows the same ratio.

Every card keeps its mark in a 24-pixel column and starts its title and its
detail row after it, so the text of machine rows, agents and processes shares
one left edge. A command one level under an agent leads with its status glyph
in a column that ends on that same edge.

Every agent card has the same three rows, whether the agent runs in a worktree
or not, focused or not; the state changes what the rows say, never the card's
shape. No row is left blank.

The first row says who it is and in what state: the provider's tile, the title
and, on the right, the state with how long the agent has held it. A badge on
the tile's lower right corner carries the state's glyph in its color, the
working one pulsing; an agent at rest has none, and its tile and title recede,
as do those of an agent telar cannot read (`unknown`). An agent in a worktree
takes its task's title, or its branch when it has none, as its title; any other
agent takes the title its session reports, or its provider's name.

The second row says what happens there, and has the row to itself: the question
or request in yellow while the agent is blocked, the error in red when it
failed, the plan's step while it works on a plan with the plan's count on the
right, its latest event while it works without one, and its final answer once
it is done or at rest. When the agent said nothing for its state the row names
what is missing, in a receding ink: `No event yet`, `No request text`, `No
error text`, `No final message`, `No signal`.

The third row says where: the project, then the tab when it is named after
neither the card nor the project, then the directory, and on the right the
branch with a dot while it has changes. For a worktree the row holds its facts
instead: the machine, the branch, the lines it added (green) and removed (red),
its files, its commits ahead and its command's outcome. The branch is left out
when it reads like the title. When the row runs short the commits ahead give
way first, then the branch, the files and the command's outcome, while the
machine and the diff stay. A plan's progress is a thin line under the rows. A
blocked or failed agent tints its card in its state's color. The header reads
`agents`. One array of at most 64 replica indices is sorted by
`agent_attention.lessThan` when snapshot identity changes, never per frame.

The top-right state reads `Working`, `Approval`, `Question`, `Review plan`,
`Needs input`, `Done`, `Failed` or `Unknown`, followed by how long the agent
has held it. Ready agents show only their status age. The duration uses `0s`
through `59s`, then `1m`, `1h` or `1d`; the same duration is never repeated
elsewhere in the card. It adds monotonic seconds since the agent snapshot
first painted. Narrow cards drop the duration, then the state word; title,
signal and project fit independently with an ellipsis.

Only the working dot pulses through six alpha steps between 1.0 and 0.65
across 17 animation frames, one frame every 120 ms of the window's frame
clock. The state word and duration remain steady.
The focused pane's card has `surface0` fill and an inner 1px `surface1` ring.
Built-in providers use the embedded symbol atlas at 60% opacity.
OpenAI, Cursor Agent and OpenCode are white masks tinted with `text`; Claude and Pi retain their source colors. Custom providers keep an unboxed glyph.
The workspace favicon remains colored and is resolved by the existing worker.
One clipped `focus_agent` hit target covers each visible card. The wheel
over the agent viewport scrolls one card pitch; the band's last pixel column is its edge and a 6 px
strip centered on it remains the resize handle.

## Geometry

Visibility lives in the client model as `sidebar_visible`, and the runtime
retains it for reconnecting clients. The runtime also retains a column-width
preference in the client layout replica; the terminal client drew a cell
sidebar at that width, and the window does not read it. `telar sidebar resize
COLUMNS` and `telar sidebar get` still write and report that column value, so
the command changes nothing the window shows: the model derives the workbench
from it only when `model.host.grid_chrome` is set, and no adapter sets it.

The window's sidebar is a band of device pixels that the renderer takes off the window width before it counts columns, the
way the top bar, tab strip and status bar come off the height. Its width is
`gui.sidebar.width` logical pixels (default 240, bounds 220..800) scaled by
the display and rounded, and an 8 logical px gap separates the edge line
from the first cell column. The band is clamped so the workbench keeps at
least 20 columns after the gap and the right window padding; a window that
cannot hold the narrowest band beside that workbench collapses it to the
workspace rail, and one that cannot hold even the rail hides the band. The width is
a disposable host preference (`SidebarPreference`) seeded from the Lua
value: `resize_sidebar` moves it by 16 logical px, dragging the edge sets
the exact width under the pointer, both clamp to the same bounds, and a
reload that changes `gui.sidebar.width` replaces it while one that does not
keeps the interactive choice. Nothing persists it outside the Lua file:
the window lease holds no data and there is no per-window preference
store. The PTY sees complete cells only; the band, the gap and trailing
pixels are chrome.

The band runs from under navigation to the status bar. Inside its 8 px
margin, `projects` precedes workspace rows in stable runtime order. Each row
shows the existing favicon or folder glyph, a bold name and the workspace's
path in the small face. Both labels fit independently with an ellipsis.
The selected workspace uses bright name and folder text, with a secondary
path. Inactive rows use neutral gray (`#737373`) for their name, path, folder and attention count; their
favicons draw at half opacity without replacing or uploading the sprite.
Only hover draws a rounded card background. Selection alone has no background,
border or accent rail.
A trailing `! N` counts blocked and failed agents; only the active project
uses the shared attention color. Agent cards retain their own focus surface. Rows are two line boxes plus 20 logical px
of vertical padding. Each visible row has one clipped `select_workspace`
target carrying its runtime ID.

The project section grows with its list, up to 40% of the inset band.
`agents` and its divider share one row below it, without a subtitle or
summary counts. Agent cards occupy the remaining height. The lists scroll
independently, including fractional trackpad movement. A workspace change,
change in its list position or resize reveals the selected row; ordinary
repaints retain manual scrolling. Headers and the resize gutter do not scroll.
The viewports belong to the delivered hit map, so pending or failed frames
cannot change which list receives a pointer event.

A collapsed sidebar keeps a workspace rail:
a band of `SidebarBand.logical_rail` (52) logical px with the same 8 px gap,
running from under navigation to the status bar. One 36 px control per
project in runtime order, 10 px apart below a 12 px inset, holds the favicon
or, without one, a 20 px tile tinted with a hue the project's name picks from
the palette's accents and holding its bold initial (`WorkspaceMark`), so
projects without favicons still differ; the rail shows no numbers. Idle
controls have no surface; hover draws `surface0` and the selected project
`surface1` with a 3 px accent pill whose rounded end shows at the rail's edge. Agent attention is a dot in
the top-right corner inside a ring of the rail's background. When the rail is too short for every project, the window
centred on the selection keeps its marks and `+N` counters above and below
select the nearest hidden project and keep the attention of the ones they
hide. Hovering a mark shows `RailTooltip` beside the rail, above the panes:
the project's name and what it runs, `N waiting`, else `N agents`, else
`N tabs`. The tooltip paints only; the mark owns the target.

Navigation spans the window and shares its row with the window's own
controls. On macOS, with `gui.window.titlebar = false`, the traffic lights
stay visible over a transparent titlebar: `TelarWindow` centres them on the
navigation row the frame reports (`telar_gui_frame.navigation`) at a 14 pt
lead and 20 pt pitch, and reports the points they cover through
`telar_gui_viewport.controls`, zero in fullscreen, with the native titlebar
and on Linux. After that room come the sidebar toggle, a glyph with a quiet
hover surface, the machine switcher, the workspace track and the tabs, which end before the palette button and the new tab button. The bar
reads in the order of what holds what: the machine, its workspaces, the tabs of
the workspace in front. The tabs keep 220 logical px before the other two get
any room, so a narrow window shortens those first: the machine's label down to
72 px, then the names of two workspaces, then the workspaces that do not fit. All
navigation still uses the shared client intents; the GUI keeps only bounded
disposable scroll and pointer state. Configured metrics and other widgets
belong in the bottom status bar.

The tab strip sits in the middle of the room the bar leaves it, between the
workspace track and the palette button, and packs its tabs side by side, each a
30 px pill with a 10 px radius: a 20 px translucent chip holding the
application mark (`tab_label.mark`, the focused application's even for a
renamed tab), the caption and a trailing status. While the prefix waits for a
digit the chips show the tabs' numbers instead, so widths never change. The
caption is `tab_label.caption`: a manual label, else the focused pane's agent
session title once it is no longer a placeholder, else the focused directory
beside the foreground application (`replay-web · fish`). The status is the
selected pane's progress report, else the tab's most urgent agent: a spinner
stepping every 120 ms while it works, a dot in the attention colour when it
waits, fails or is done. The spinner's ring is drawn whole behind its arc, so
at a tab's size it reads as a ring and not as a chevron. The tabs sit in one
well, and the selected one is a lens over it: a ring and a fill lighter than
the well's; hover gives the others a quieter fill and brightens their mark.
When every caption fits, the tabs are all as wide as the widest of them needs,
so the selection slides over a still row and short captions leave the bar the
room they do not use. Otherwise
the selected tab keeps its whole caption up to 300 px or 55 % of the strip.
The others share the rest at the richest fit that holds all of them: whole
captions up to 220 px, then captions truncated to a common cap no shorter
than 56 px of text. When not every caption fits, the tabs nearest the
selection keep one and the farther ones shrink to their chip, so no usable
room is left over. Truncated captions fade over their last 20 px instead of
ending in an ellipsis. Past the chips, the tabs farthest from the selection
hide behind a `+N` counter that selects the nearest hidden tab and keeps
their attention dot, and `+` follows the last visible control. While the
pointer rests on the strip, the strip stays where it is and its widths stay
laid out around the tab they were
built for, so a click changes the selection without moving tabs under the
pointer; leaving the strip relayouts it, and a selection the frozen layout
would hide rebuilds it at once.

During the empty tab-model phase of a workspace handoff, the top bar retains
the last delivered project identity while it remains in the workspace list.
Indicators, selection and the overflow window remain in place until arrival.
The identity is stored with the delivered hit map; failed frames cannot replace
it. This retains no pane data and does not change navigation authority.

## Detector wiring

`runtime_messages.handleServerMessage` hands an agent snapshot to
`agent_snapshot.applyAgentSnapshot`, which:

1. maps runtime agent records to bounded `AgentInput` values;
2. commits the replica and `Version.agents` in `ClientModel` through
   `agent_snapshot.reconcile`, which rejects stale revisions;
3. synchronizes attachment resources;
4. emits bounded actionable alerts;
5. synchronizes the sidebar animation.

The snapshot path never requests a draw for the replica itself. The window
observes the model version after the event, and its next frame projects the
latest snapshot; `SidebarState.observe` sorts it again only when the snapshot
identity changes. Several runtime revisions inside one frame interval
therefore fold into one projection.

Only status changes for identities present in the previous revision can emit
an alert. Transitions to `blocked`, `done` and `failed` are actionable, and
the use case caps them to the notification center's fixed capacity. Agent
sounds remain separate runtime decisions; the client accepts a sound only
when its exact pane generation exists in `ClientModel`.

Detection remains on the observation path. Snapshot rendering and input
routing perform no filesystem, process, JSON, network, or plugin work.

A lifecycle report from the agent's own hooks decides the status while it is
valid: working, blocked with its reason, ready. Without one, the screen
decides: a visible permission prompt is blocked, a working phrase is working,
and a confirmed input prompt is ready. Codex's branded input prompt confirms
`ready` once no working phrase remains visible above it. Every record carries
its source, confidence, process and session identity, sequence, timestamps,
and expiry. None of these presentation hints authorizes approval or input.
