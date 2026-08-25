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
