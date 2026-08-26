# Flow index

A flow crosses capabilities and may cross processes. Each document starts at
one external trigger, names every process entrypoint and protocol message, and
ends at the externally visible effect. Search for the symbols in backticks;
line numbers are intentionally omitted because symbols survive refactors.

| Flow | Trigger | Visible result | Proof |
| --- | --- | --- | --- |
| [Host input to screen](host-input-to-screen.md) | Bytes arrive from the host TTY | A Telar action is consumed, or child output is presented | Input router unit tests and transport integration tests |
| [Pane launch](../adr/0001-pane-launch-is-a-runtime-transaction.md) | Client sends an open/create request | A running runtime pane is confirmed to the client | Launch fault-injection integration test |

Add a flow when a behavior crosses an asynchronous boundary, a process
boundary, or three capability owners. Do not duplicate local implementation
details already expressed by a capability's tests.

