# telar

telar models long-lived terminal work owned by a runtime and observed or
controlled by disposable clients.

## Language

**Pane launch**:
The act of starting a new runtime-owned pane from a requested command and
terminal size. It ends when the runtime owns a usable pane, independently of
any client's attachment or confirmation.
_Avoid_: Pane creation, pane spawn

**Client confirmation**:
The per-connection acknowledgement that exposes a completed pane launch to one
client.

**Pane launch state**:
The lifecycle of a pane whose launch has not settled. A pane is `starting`,
`running`, or `aborting` during this lifecycle.

**Launch attempt**:
A history record for a child process that was spawned but whose pane launch did
not complete. It is distinct from a normal pane session.

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
