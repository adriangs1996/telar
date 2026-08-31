# telar

telar models long-lived terminal work owned by a runtime and observed or
controlled by disposable clients.

## Language

**Runtime instance**:
One running lifetime of Telar's backend, including its authoritative runtime
model and the physical resources that support it until ordered shutdown. Its
implementation composes `Application`, `Resources` and `EventLoop`; none is a
second runtime.
_Avoid_: Server, Runtime model

**Runtime application**:
The runtime-owned application state and orchestration around `RuntimeModel`.
It applies use cases, manages disposable client sessions and enforces
cross-capability invariants, but does not own the process event loop or acquire
physical resources.
_Avoid_: Server, AppState, Runtime model

**Runtime resources**:
The live allocators, environment, listener, proxy, telemetry, client-session
storage and history adapter acquired for one runtime lifetime. They support the
model but are neither semantic state nor persistable checkpoint data.
_Avoid_: Runtime model, Global state

**Runtime model**:
The authoritative semantic state owned by one running runtime. Client
projections and durable checkpoints derive from it; infrastructure resources
support it without becoming its authority.
_Avoid_: Public state, Server state, AppState

**Runtime checkpoint**:
A durable data-only representation of the restorable parts of a runtime model.
It excludes live resources and does not promise child-process or PTY continuity.
_Avoid_: Runtime snapshot, Process snapshot

**Workspace aggregate**:
The runtime-owned workspace identity, path, name and ordered tabs whose rules
change as one unit.
_Avoid_: Workspace store, Workspace record

**Workspace repository**:
The in-memory collection boundary through which workspace aggregates are
located and retained in the runtime model, without defining their behavior or
durable representation.
_Avoid_: Workspace manager, Workspace database

**Tab removal**:
The committed disappearance of a tab from its workspace aggregate, whether
requested directly or caused by the loss of its final pane. It also removes an
aggregate left with no tabs.
_Avoid_: Tab close (for the committed fact), Pane close

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

**Agent**:
The runtime-owned identity and lifecycle of one coding-agent session associated
with an exact pane generation. Process, proxy, and screen observations describe
the same agent; none of those observations is an agent by itself.
_Avoid_: Agent record, detector result

**Model exchange**:
One inference request and its provider response. Several model exchanges may
belong to the same agent session and may overlap in time.
_Avoid_: Agent turn, HTTP connection

**Transport completion**:
The end of an HTTP response stream. It says that no more response bytes remain,
but does not say why the model stopped or whether the agent is ready.
_Avoid_: Provider turn completion, agent completion

**Provider turn completion**:
An explicit provider-protocol outcome saying that one model exchange ended
without requesting tool execution or continuation. It is evidence that the
agent can become ready once no other model exchange remains.
_Avoid_: Transport completion, agent ready

**Agent tracker**:
The runtime authority that reconciles process, proxy, and screen observations
with the corresponding agents and publishes their client-facing state.
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
