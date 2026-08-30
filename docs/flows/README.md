# Flow index

A flow crosses capabilities and may cross processes. Each document starts at
one external trigger, names every process entrypoint and protocol message, and
ends at the externally visible effect. Search for the symbols in backticks;
line numbers are intentionally omitted because symbols survive refactors.

| Flow | Trigger | Visible result | Proof |
| --- | --- | --- | --- |
| [Host input to screen](host-input-to-screen.md) | Bytes arrive from the host TTY | A Telar action is consumed, or child output is presented | Input router unit tests and transport integration tests |
| [Pane launch](../adr/0001-pane-launch-is-a-runtime-transaction.md) | Client sends an open/create request | A running runtime pane is confirmed to the client | Launch fault-injection integration test |
| [Pane attachment](pane-attachment.md) | Tab reconciliation finds a detached pane | The active client accepts frames from the runtime attachment | Model, recovery, presenter and protocol tests |
| [Pane split](pane-split.md) | User requests a horizontal or vertical split | The created runtime pane enters the exact client tab and the presenter observes one commit | Request, model, race, recovery and protocol tests |
| [Tab rename](tab-rename.md) | User submits the tab-name prompt | The runtime commits the label and the presenter observes the canonical replica | Request, model, presenter and transport tests |
| [Tab removal](tab-removal.md) | Client requests closure, or the final pane exits | The runtime removes the tab and clients reconcile their workspace | Handler, controller, backpressure and transport tests |
| [Tab snapshot reconciliation](tab-snapshot-reconciliation.md) | Bootstrap, tab selection or resync requests canonical pane membership | The client preserves retained pane state and repairs disposable resources | Model, resource, protocol and presenter tests |
| [Workspace snapshot reconciliation](workspace-reconciliation.md) | User renames a workspace, or the runtime requests resync | The client commits the latest workspace replica and repairs disposable resources | Request, model, capacity, resource and presenter tests |

Add a flow when a behavior crosses an asynchronous boundary, a process
boundary, or three capability owners. Do not duplicate local implementation
details already expressed by a capability's tests.
