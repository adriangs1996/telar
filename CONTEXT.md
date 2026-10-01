# telar

telar models long-lived terminal work owned by a runtime and observed or
controlled by disposable clients.

## Language

**Runtime instance**:
One running lifetime of Telar's backend, including its authoritative runtime
model and the physical resources that support it until ordered shutdown.
_Avoid_: Server, Runtime model

**Runtime resources**:
The live processes, descriptors, sockets, workers and storage connections
acquired for one runtime lifetime. They support the runtime model but are
neither its state nor persistable checkpoint data.
_Avoid_: Runtime model, Global state

**Runtime model**:
The authoritative semantic state owned by one running runtime. Client
projections and durable checkpoints derive from it; infrastructure resources
support it without becoming its authority.
_Avoid_: Public state, Server state, AppState

**Client model**:
All disposable state owned by one client connection: its interaction and
navigation choices, bounded replicas of authoritative runtime state, the facts
its host reported and the requests it has in flight.
_Avoid_: AppState, Client runtime, UI state

**Client application**:
The use cases and operational policy of one disposable client, independent of
how its host supplies input or presents its model.
_Avoid_: Window logic, Second client, Shared client instance

**Prepared presentation**:
One client projection consumed by its presentation adapter but not yet confirmed
as delivered. It does not discharge the client's frame acknowledgement obligation.
_Avoid_: Presented frame, Received frame

**Presentation delivery**:
A client's confirmed delivery of one prepared presentation. It permits exact
frame acknowledgements but does not claim that pixels reached the user's eyes.
_Avoid_: Frame receipt, Composition, Client delivery

**Presentation adapter**:
The implementation that shows one client's projection on a host and turns host
events into host input. The native GUI, the headless client and the headless
test adapter are presentation adapters; each owns its chrome, hit testing and metrics.
_Avoid_: Renderer, frontend, view layer

**Client chrome**:
Everything a presentation adapter shows that is not the content of a pane:
sidebar, bars, modals, pickers and Telar views. Its look belongs to the
adapter; the state it shows belongs to the client model.
_Avoid_: UI, widgets, decorations

**Bar component**:
One item a configuration places in a bar, a tooltip or a bar panel, from a
closed vocabulary Telar draws itself: a label, a meter, a group and the like.
The configuration says what it shows; the adapter decides how it looks.
_Avoid_: Widget, segment, module

**Bar panel**:
The panel a bar component opens above the bottom bar, filled from its own
configured source while it is open. Disposable client state.
_Avoid_: Popup, modal, dropdown

**Pick list**:
The command palette on the options of a configured pick, written in the
configuration or printed by a command. Choosing one runs the pick's
`on_select` command with it as one argument. Disposable client state.
_Avoid_: Dropdown, selector, menu

**Telar view**:
Content Telar composes from client and runtime projections instead of from a
PTY, such as a history browser or a change review. The layout may
place it beside terminal panes; its state never lives in the adapter.
_Avoid_: GUI pane, virtual pane, widget pane

**Attachment generation**:
One lifetime of a client's attachment to a pane, distinct from the pane's own
lifetime. Reattachment begins a new generation even when frame numbers repeat.
_Avoid_: Pane generation, Frame ID

**Runtime checkpoint**:
A durable data-only representation of the restorable parts of a runtime model.
It excludes live resources and does not promise child-process or PTY continuity.
_Avoid_: Runtime snapshot, Process snapshot

**Limit**:
A fixed bound telar enforces to keep its memory fixed, named by the stable
identifier of the constant that sets it (`bars.max_bar_actions`), with the
noun it counts and its value.
_Avoid_: Quota, Cap, Capacity error

**Limit reach**:
One time work asked for more than a limit allows: the limit and, when known,
the amount asked for. Telar keeps what fits, drops the excess, counts the
reach and shows it at most once per interval.
_Avoid_: Overflow, Limit hit, Capacity failure

**Workspace**:
The runtime-owned workspace identity, path, name and ordered tabs.
_Avoid_: Workspace aggregate, Workspace store, Workspace record

**Tab removal**:
The committed disappearance of a tab from its workspace, whether requested
directly or caused by the loss of its final pane. It also removes a workspace
left with no tabs.
_Avoid_: Tab close (for the committed fact), Pane close

**Pane launch**:
The act of starting a new runtime-owned pane. It ends when
the runtime owns a usable pane, independently of any client's attachment.
_Avoid_: Pane creation, pane spawn

**Launch working directory**:
The local directory where a pane's child process starts. A launch may name it
explicitly or inherit it from a source pane.
_Avoid_: Workspace path, client path

**Pane working directory**:
The runtime's current working-directory value for one pane. It changes as the
pane's shell changes directory and can be inherited by a later pane launch.
_Avoid_: Workspace path, launch path

**Workspace path**:
The stable local directory associated with a workspace for identity, display,
and history scope. It does not change when one of the workspace's panes changes
its working directory.
_Avoid_: Pane working directory, current path

**Client confirmation**:
The per-connection acknowledgement that exposes a completed pane launch to one
client.

**Client delivery**:
The per-client policy that selects and commits the next bounded runtime message.
Queued management responses coexist with projections of the latest authoritative
runtime state; visual state is never accumulated as a replay.
_Avoid_: Output queue, socket writer

**Attachment synchronization**:
The per-client, per-pane state that tracks acknowledged cells, graphics credit,
snapshots and transfer progress. It is disposable and does not own pane state.
_Avoid_: Pane replica, client pane

**Pane launch state**:
The lifecycle of a pane whose launch has not settled. A pane is `starting`,
`running`, or `aborting` during this lifecycle.

**Launch attempt**:
A history record for a child process that was spawned but whose pane launch did
not complete. It is distinct from a normal pane session.

**Proxy secret**:
The one capability that authorizes a child of the runtime to use Telar's
proxy. It lives in the proxy directory, survives runtime restarts and rotates
only when its file is deleted.
_Avoid_: Proxy credential, proxy token, proxy authentication

**Host input**:
User input received from a client's host before Telar classifies its intent.
The host may be a terminal or a native window.
_Avoid_: Raw input, keyboard input

**Input routing**:
The decision that classifies host input as a Telar action or pane input.
_Avoid_: Keybinding resolution

**Input mode**:
The single owner of host input at any moment: normal (the pane), copy mode
(the selection), or the name prompt (the editor). Input routing consults it
once per event; exactly one mode is active.
_Avoid_: Modal state, capture flag

**Copy mode**:
The input mode where host input drives a cursor and selection over a pane's
retained history instead of reaching the child process.
_Avoid_: Scrollback mode, selection mode

**Name prompt**:
The input mode where host input edits a name — a tab rename, a workspace
rename, or a new workspace — until submitted or cancelled.
_Avoid_: Rename dialog, modal input

**Path picker**:
The prompt that fuzzy-finds a path under the focused pane's working directory
and pastes it at the pane's cursor. The runtime indexes and ranks; the client
keeps the browsed root, the page and the selection.
_Avoid_: File finder, path completion (the new-workspace directory list)

**Telar action**:
A semantic instruction handled by Telar rather than forwarded as input to a
pane. It may affect client state or request a runtime-owned change.
_Avoid_: Keybinding

**Pane input**:
Semantic input destined for the child process owned by a pane after input
routing has chosen that destination.
_Avoid_: Raw input, forwarded key

**Focused pane**:
The pane in the client's active tab that receives pane input. Each tab remembers
its focused pane so the client can restore that focus when the tab becomes
active.
_Avoid_: Selected pane, active pane

**Pane display position**:
The one-based position of a pane in its tab's visible ordering, shown as
`pane N`. It is not the pane's identity, and changing focus does not alter it.
_Avoid_: Pane ID, focused position

**Tab layout**:
The client-owned arrangement of a tab's pane splits, including their direction
and relative size. Pane focus and pane display position do not define it.
_Avoid_: Pane order, workspace layout

**Workspace bookmark**:
A client's remembered return point for a workspace: its tab, focused pane, and
tab layout. It is disposable and does not belong to the runtime.
_Avoid_: Runtime layout, workspace state

**Focused agent**:
The agent associated with the focused pane, if that pane has an agent. A client
may have no focused agent even when the runtime reports other agents.
_Avoid_: Selected agent, active agent

**Agent**:
The runtime-owned identity and lifecycle of one coding-agent session associated
with an exact pane generation. Process, screen and lifecycle observations
describe the same agent; none of those observations is an agent by itself.
_Avoid_: Agent record, detector result

**Pane descent**:
A process descends from a pane when its chain of parent processes reaches the
pane's root process. The runtime checks it for the process at the other end of
a connection, and only such a connection may report for a pane in the name of
an agent: an inherited `TELAR_PANE_ID` names a pane but does not prove that a
process runs in it.
_Avoid_: Pane ownership, pane ancestry

**Agent tracker**:
The runtime authority that reconciles process, screen and lifecycle
observations with the corresponding agents and publishes their client-facing
state.
_Avoid_: Agent registry, Agent observer, Agent repository

**Open agent**:
An agent session whose process still belongs to a pane. Being open says nothing
about whether the agent is working or waiting for input.
_Avoid_: Active agent

**Working agent**:
An open agent with current model or tool work in progress. An agent showing its
input prompt is not working.
_Avoid_: Running agent, busy process

**Ready agent**:
An open agent waiting for user input with no current work in progress.
_Avoid_: Idle process

## Agents

**Project**:
A git repository identified by its common directory, so every worktree of
that repository belongs to the same project. A directory that is not a
repository is its own project, keyed by path.
_Avoid_: Repo, workspace path

**Blocked reason**:
What a blocked agent is asking for, as an official hook reported it. Screen
evidence never provides one.
_Avoid_: Permission text, prompt text

**Provider option**:
A configurable value a provider's manifest declares, such as model, effort or
permission mode, together with the flag that sets it at launch and the live
command that changes it on a running agent.
_Avoid_: Setting, flag, trait

**Live command**:
The agent's own command, typed into its input on the user's behalf, that
changes a provider option on a running agent. Its effect is confirmed only by
the transcript.
_Avoid_: Slash command, remote setting

**Worktree**:
A Git linked worktree the runtime tracks as a place where work happens. It
belongs to one project and hangs from one source workspace; its tabs live in
a child workspace bound to it.
_Avoid_: Checkout, Worktree workspace

**Source workspace**:
The project workspace a worktree hangs from in the UI and returns to with
`leave-worktree`.
_Avoid_: Parent workspace

**Worktree handle**:
The branch name shown for a worktree, without the `worktree-` prefix Claude
Code adds. Paths are never shown in its place.
_Avoid_: Worktree path, Worktree name

**Worktree origin**:
`telar` for a worktree created through `telar worktree` or its hooks,
`external` for one found by observing an agent's directory.

**Coordinator**:
An agent in a project's own checkout that delegates tasks to agents in
worktrees and follows them through `telar agent` and `telar worktree`.
_Avoid_: Orchestrator, Manager agent

**Task**:
The work delegated to one worktree, named by its required title. It is what
the user and the coordinator refer to.
_Avoid_: Job, Ticket

**Task card**:
The sidebar card of an agent that works in a worktree: task title, what it is
doing now, its branch handle and diffstat.
_Avoid_: Worktree card

**Peek**:
A modal that shows one agent's state and last pane rows, and sends it a
message, interrupt, diff or open, without changing tab or focus.
_Avoid_: Preview, Popover

## Machines

**Machine**:
One computer whose runtime a client or the CLI can reach, through the local
socket or an SSH connection. A machine runs one runtime per account; runtimes
never know about each other.
_Avoid_: Host, server, remote, node

**Local machine**:
The machine the client or CLI process runs on. It needs no profile; it answers
to the label `machines.json` gives it, or its host name.
_Avoid_: Localhost, home machine

**Machine profile**:
The saved record of how to reach a machine: a stable id, a label, an SSH
destination, an optional color, whether windows connect to it, and after
setup the path of its telar and how its agent logins stood. It never holds
credentials.
_Avoid_: Remote config, connection, host entry

**Machine label**:
The name a command line and the chrome use for a machine. It can change; the
profile's id never does.
_Avoid_: Alias, hostname

**Active machine**:
The machine whose runtime a window presents and sends input to. A window has
exactly one.
_Avoid_: Current host, selected server

**Machine setup**:
Making a machine ready for the window with `telar machine setup`: this build
of telar at a path the profile saves, the person's agents installed and
configured there, and each agent's own login on that machine. It is
idempotent, and it never moves a credential.
_Avoid_: Provisioning, bootstrap, install

**Agent login**:
One agent's own account session on one machine, made through the agent's
official flow and revocable there alone. Setup records whether it is
`pending`, `done` or `failed` as it last saw it.
_Avoid_: Credentials sync, token copy

**Dispatch**:
Starting work on another machine: one CLI command, a worktree or an agent. The
machine that dispatches sends what the work needs, such as commits, and a
failure there never falls back to the local machine.
_Avoid_: Remote exec, offload

**Repository identity**:
The normalized URL of a repository's `origin` remote: host/path with userinfo
and default ports removed, nondefault ports retained. It finds the clone of
one project on another machine; it never decides where work runs. A separately
sanitized transport URL preserves non-secret origin details.
_Avoid_: Repo id, project key

## Change review

**Directed session**:
A synchronous collaboration in a pane where the user directs project changes
through natural language, contextual code review and optional direct editing,
taking exclusive collaboration turns with one agent. The
agent works without subagents in a working tree that other agents do not share.
_Avoid_: Permission mode

**Collaboration turn**:
An exclusive period of a directed session assigned to the user or the agent;
the other participant must wait for its owner to hand control back before
advancing the shared work. It is independent of the provider's model exchanges.
_Avoid_: Model exchange, Provider turn completion

**Explanation turn**:
An agent collaboration turn whose scope is answering the user's contextual
question without implementing further changes. Earlier implementation
instructions do not authorize additional implementation during this turn.
_Avoid_: Continue implementation

**Implementation turn**:
An agent collaboration turn authorized to work on one agreed change objective
and then return control to the user. The objective can involve multiple files.
_Avoid_: Complete the whole task

**Review step**:
A project change with an agreed objective, developed and reviewed across one
or more collaboration turns. It becomes accepted only through an explicit
user decision.
_Avoid_: Tool call, Commit, Collaboration turn

**Step draft**:
The current project code being developed and reviewed for a step, already
present in the directed session's private working tree before acceptance.
_Avoid_: Accepted version

**Review revision**:
A retained code version delivered for review within a step, linked to the
conversation about that version. Internal edits made before that delivery do
not become separate review revisions.
_Avoid_: Tool call, Final task result

**Step acceptance**:
The user's explicit decision that a review step is suitable to advance from,
independently of whether it passes validation. Asking a question, editing code,
or handing control back does not itself accept the step.
_Avoid_: Turn handoff

**Step discard**:
The rejection of a step draft, restoring the state preceding that step,
including reversal of both human and agent contributions to it. The rejection
retains the user's feedback on how the work should proceed.
_Avoid_: Request revision

**Experiment area**:
A designated space for a directed session's disposable utilities and
experiments outside the project changes under review. Incorporating its
contents into the project requires a change proposal.
_Avoid_: Untracked files

## Fleet operations

**Execution**:
A runtime-owned pipe-backed command, addressed by a caller-chosen random id for
one runtime lifetime. Its result and bounded byte streams outlive its workspace
and requesting client. It is distinct from a terminal pane.

**Administration workspace**:
The destination-owned workspace lazily used by executions without an explicit
workspace. Its ownership is recorded by identity, never inferred from its name.

**Repository preparation**:
Receiving selected committed history from a dispatching clone and publishing a
verified local clone, independently of project setup.

**Project setup**:
An explicitly authorized command that prepares a worktree environment before
its task starts. Its execution outcome is distinct from Git readiness.
