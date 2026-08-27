# telar

telar models long-lived terminal work owned by a runtime and observed or
controlled by disposable clients.

## Language

**Pane launch**:
The act of starting a new runtime-owned pane from a requested command and
terminal size. It ends when the runtime owns a usable pane, independently of
any client's attachment or confirmation.
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

**Proxy credential**:
A pane-generation-scoped capability that authorizes one child to use Telar's
observation proxy. It expires when pane launch aborts or that pane generation
retires.
_Avoid_: Proxy token, proxy authentication

**Host input**:
User input received from the host terminal before Telar classifies its intent.
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
