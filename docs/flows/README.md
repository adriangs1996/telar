# Flow index

A flow crosses capabilities and may cross processes. Each document starts at
one external trigger, names every process entrypoint and protocol message, and
ends at the externally visible effect. Search for the symbols in backticks;
line numbers are intentionally omitted because symbols survive refactors.

| Flow | Trigger | Visible result | Proof |
| --- | --- | --- | --- |
| [Agent snapshot](agent-snapshot.md) | Runtime agent evidence changes | The client commits one bounded replica, emits actionable transitions and the presenter projects the latest revision | Storage, model, effect-order, protocol and presenter tests |
| [Clipboard image preview](clipboard-image.md) | An attachment-capable pane receives `Ctrl+V` | The child gets its paste first, then one current bounded preview enters paced client media | Identity, ownership, bounds, stale-result and presenter tests |
| [Configuration reload](config-reload.md) | A watched config, module, plugin or trust file changes | One validated generation replaces client state, resources and owned Lua/plugin objects before paced presentation | Validation, ownership, model, effect-order and presenter tests |
| [Copy mode](copy-mode.md) | User enters scrollback, moves or selects text | Model-owned copy state is projected on a paced frame, and an accepted selection reaches the runtime | Pure-state, model, effect-order, backpressure and presenter tests |
| [Host capabilities](host-capabilities.md) | The exterior terminal answers a probe or its deadline expires | The client commits per-host features, projects fallbacks and lets the presenter observe one version | Translation, model, effect-order, failure and presenter tests |
| [Host input to screen](host-input-to-screen.md) | Bytes arrive from the host TTY | A Telar action is consumed, or child output is presented | Input router unit tests and transport integration tests |
| [Host resize](host-resize.md) | The exterior terminal grid or pixel geometry changes | The client commits one bounded geometry, resizes presentation resources and offers active pane sizes to the runtime | Validation, model, effect-order, backpressure and presenter tests |
| [Lua action](lua-action.md) | Input routing matches a configured callback or expression | One validated semantic effect batch or bounded input decision enters existing client use cases | VM-bound, model, validate-before-apply, input and presenter tests |
| [Name prompt](name-prompt.md) | User opens, edits, cancels or submits a naming prompt | One model-owned editor is presented, or its accepted intent reaches the matching request use case | State, effect-order, input-adapter and presenter tests |
| [Notifications](notifications.md) | Runtime event, request failure or local client diagnostic publishes a notice | The model owns one bounded lifecycle, while immutable renderers project it and ID-based interactions return through use cases | State, effect-order, timer, input and presenter tests |
| [Pane launch](../adr/0001-pane-launch-is-a-runtime-transaction.md) | Client sends an open/create request | A running runtime pane is confirmed to the client | Launch fault-injection integration test |
| [Pane attachment](pane-attachment.md) | Tab reconciliation finds a detached pane | The active client accepts frames from the runtime attachment | Model, recovery, presenter and protocol tests |
| [Pane focus](pane-focus.md) | User, notification or sidebar selects a pane | The client commits focus, orders terminal reports and resizes fullscreen geometry before presentation | Model, intent, effect-order and presenter tests |
| [Pane frame](pane-frame.md) | Runtime publishes a bounded terminal projection | The client commits it, presents it and acknowledges only after the host flush | Model, recovery, resource, presenter and protocol tests |
| [Pane graphics](pane-graphics.md) | Runtime publishes image resources and placements | The client reconciles physical resources and semantic fallback state, then the presenter schedules bounded cell and media passes | Store, model, effect-order, recovery and presenter tests |
| [Pane fullscreen](pane-fullscreen.md) | User, Lua or plugin toggles the focused pane | The client retains tiled layout, publishes visible geometry and lets the presenter compose fullscreen | Model, geometry, IPC and presenter tests |
| [Pane input](pane-input.md) | Routed keyboard, paste or mouse input targets a child | The client validates one active target, applies viewport policy and delivers bounded bytes to the runtime | Model, encoding, effect-order, backpressure and protocol tests |
| [Pane metadata](pane-metadata.md) | Runtime CWD or foreground observation changes | The client stores the bounded replica and the presenter updates only affected projections | Model, allocation-failure, presenter and protocol tests |
| [Pane resize](pane-resize.md) | User, Lua or plugin moves a focused pane edge | The client commits bounded layout geometry, offers attached sizes to the runtime and lets the presenter observe the change | Layout, model, IPC and presenter tests |
| [Pane viewport](pane-viewport.md) | User scrolls retained output, sends pane input or moves in copy mode | The client commits a bounded scroll position, synchronizes its runtime attachment and lets the presenter recompose it | Model, effect-order, IPC-order and presenter tests |
| [Pane split](pane-split.md) | User requests a horizontal or vertical split | The created runtime pane enters the exact client tab and the presenter observes one commit | Request, model, race, recovery and protocol tests |
| [Pane closure](pane-closure.md) | A user requests closure, or a pane child exits | The authoritative exit retires pane state and the presenter observes active changes | Request, model, lifecycle, resource and presenter tests |
| [Plugin action](plugin-action.md) | Input routing produces a configured plugin action | One current digest-authorized effect batch enters shared client use cases and paced presentation | Lifecycle, identity, generation, authorization and presenter tests |
| [Proxy status](proxy-status.md) | Client requests the runtime's current interception state | The client commits each boolean transition, announces it and lets the presenter project the top-bar badge | Delivery, model, effect-order and presenter tests |
| [Request failure](request-failure.md) | Runtime rejects an accepted client request | The client consumes its typed continuation once, repairs disposable state and reports a targeted notice or fatal loss | Correlation, policy, recovery-order, notification and protocol tests |
| [Resync required](resync-required.md) | Runtime drops a canonical client update under bounded response backpressure | The client coalesces a snapshot, follows the surviving predecessor or exits | Delivery, policy, coalescence, handoff and presenter tests |
| [Sidebar toggle](sidebar-toggle.md) | User, Lua or plugin toggles the sidebar | The client commits chrome state, resizes attached panes and lets the presenter observe the change | Model, effect-order, geometry and presenter tests |
| [System metrics](system-metrics.md) | Runtime host health changes | The client commits one latest-state replica and the presenter projects it into the status bar | Sampler, delivery, schema, model and presenter tests |
| [Tab creation](tab-creation.md) | User requests a new tab | The runtime creates the tab and the client commits its canonical identity with the requested geometry | Request, transaction, model, attachment and presenter tests |
| [Tab move](tab-move.md) | User moves the active tab left or right | The runtime returns an absolute position and the client commits it without changing active identity | Request, model, protocol and presenter tests |
| [Tab rename](tab-rename.md) | User submits the tab-name prompt | The runtime commits the label and the presenter observes the canonical replica | Request, model, presenter and transport tests |
| [Tab removal](tab-removal.md) | Client requests closure, or the final pane exits | The runtime removes the tab and clients reconcile their workspace | Handler, controller, backpressure and transport tests |
| [Tab selection](tab-selection.md) | User selects a tab by identity, position or offset | The client commits one active identity, repairs attachments and lets the presenter observe the change | Target, model, attachment and presenter tests |
| [Tab snapshot reconciliation](tab-snapshot-reconciliation.md) | Bootstrap, tab selection or resync requests canonical pane membership | The client preserves retained pane state and repairs disposable resources | Model, resource, protocol and presenter tests |
| [Workspace snapshot reconciliation](workspace-reconciliation.md) | User renames a workspace, or the runtime requests resync | The client commits the latest workspace replica and repairs disposable resources | Request, model, capacity, resource and presenter tests |
| [Workspace creation](workspace-creation.md) | User submits the new-workspace prompt | The runtime creates one workspace and the client replaces its projection in one semantic commit | Transaction, ownership, model, protocol and presenter tests |
| [Workspace handoff](workspace-handoff.md) | User navigation or runtime lifecycle selects another workspace | The client presents one empty departure and one atomically confirmed arrival | Ordering, model, recovery, resource and presenter tests |
| [Workspace list snapshot](workspace-list-snapshot.md) | Runtime workspace membership, order, name or tab count changes | The client commits one bounded navigation replica and the presenter projects the latest revision | Storage, model, protocol and presenter tests |
| [Workspace list toggle](workspace-list-toggle.md) | User, Lua, plugin or top bar collapses the workspace list | The client commits chrome state and the presenter alone updates its view projection | Model, intent and presenter tests |

Add a flow when a behavior crosses an asynchronous boundary, a process
boundary, or three capability owners. Do not duplicate local implementation
details already expressed by a capability's tests.
