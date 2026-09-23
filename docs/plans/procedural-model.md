# Migration to flat procedural models

Target: [architecture](../architecture.md). Names: [naming](../naming.md).
Decision: [ADR 0017](../adr/0017-keep-each-process-state-in-one-flat-model.md).

The code moves by vertical slice. Each slice moves one set of flows to the
flat model, deletes the old path in the same commit, and leaves every suite
green. A slice is done when its flows read from `update` to the model without
forwarding functions, context structs or ports, and the metrics below did not
get worse.

## Metrics

Measured on `4988caf5`. Record them at the end of every slice.

| Metric | Baseline | After slice 4 |
| --- | --- | --- |
| First-party Zig files under 20 lines | 1,618 of 3,000 | 1,528 of 3,009 |
| `context: *anyopaque` ports | 192 fields in 82 files | 108 fields in 51 files |
| `TerminalClient.of` / `GuiClient.of` uses (production) | 157 / 24 | 0 / 0 |
| Fields in the client `Version` | 27 | 27 |
| Key press to pane input, TUI / GUI | ~26 hops in 10 files / ~36 in 14 | not remeasured |
| PTY bytes to client frame, runtime | ~20 hops in ~24 files | ~12 calls in ~8 files |
| `LayoutSnapshot` rebuilds per GUI frame | 5 fixed, plus one per notification and one per pump | at most 1, only when its tab, revision or area changed |

Performance slices also run the `perf-pass` probe and benchmarks against the
previous slice.

## Bugs found by the audit

Fix each with a test that fails on the old code, before or within the slice
that touches it.

1. The initial configuration never reaches the client: history visibility,
   enter-runs, match mode, notification delivery and light/dark themes are
   copied only in `AttachedClient.adoptConfiguration`, and the first reload
   returns `.unchanged` until the file changes. Present on `main`.
2. After a reload, `AttachedClient.options.lua_generation`, `plugin_registry`
   and `trust_store` point to freed memory. Nothing reads them after startup
   today.
3. A client request pumps only its own session (`client_events.handleMessage`).
   Other clients flagged for workspace resync wait for the next `pumpAll`,
   which on an idle runtime is the one-second agent tick.
4. The GUI adopts a reloaded configuration inside `draw`, contradicting
   `docs/flows/client-event-dispatch.md`. Kept by decision in slice 4: the
   adoption swaps the renderer and its font atlas, which is only safe when no
   frame is in flight, and adopting the model earlier would draw frames with
   the new chrome theme over the old terminal renderer while a font restages.
   The flow document now states that font and configuration adoption run in
   `draw`.

## Slices

1. **Rules and tooling.** Done in this change: the architecture, naming,
   invariants and source-layout documents; five-parameter limit; private
   helper types in their owner file; capability lists removed from the client
   boundary checker. Pending: a codestyle rule that method receivers are
   named `self`, with an automatic fix. It runs after slices 2 and 3 turn most
   of today's methods into procedures that take `model`.
2. **Tabs, panes and layouts in the client.** Done. `Tabs` (ordered rows,
   each with its layout tree) and `Panes` (every pane behind one id index)
   replace `TabsModel`, `Tab` and `MultiplexerModel`; the nested lookups in
   `applyPaneFrame` and the `tabForPane` plus `find` pairs are gone. The
   composer draft (4,128 of a pane's 4,712 bytes) moved to a `Composer`
   allocated on first use, so `Pane` is 584 bytes and `Model` went from
   918,304 to 605,504 bytes. The other agent fields total about 100 bytes and
   stay on the pane. `pane_frame.receive` waits for slice 3, which moves the
   outbox into the model.
3. **The rest of the client model.** Done. The sixteen `data.*` fields beside
   `AttachedClient.model`, the configuration mirrors (bugs 1 and 2), path
   completion, clipboard capture, change review and startup become fields and
   tables of `ClientModel`. One copy of configuration. `application/` and
   `operations/` merge into flow files; the three pointer-routing contexts go.
4. **One client dispatch and the host boundary as data.** `update` handles the
   eight branches both adapters duplicate. Workers start from procedures and
   report through the shared inbox, removing the seven identical ports. Host
   facts are written into `model.host`; host requests leave through
   `model.to_host`. Removes `of()`, the stub ports and the presentation
   lifecycle copy each adapter keeps. Fixes bug 4.

   Done. `client.Message` and `client.Job` replace the six worker ports;
   sound, system notices, the local clock and the configuration watch run the
   same on every host. `model.to_host` carries clipboard writes, terminal
   notices, media capture, placement invalidation, pane input for pacing, and
   input resume and rebind. The model holds the themes and the requested
   sidebar renderer and derives the workbench (`workbench.region`); the TUI
   view follows it after every event. One presentation lifecycle lives in
   `AttachedClient.presentation`. Adapter handlers take their adapter, so
   `of()` is gone. The outbox is `model.to_runtime` and `pane_frame.receive`
   queues its own answer. Kept as synchronous ports on purpose: chrome hit
   testing, the graphics store and the attachment shelf (both generic over
   each host's delivery state), the GUI's conversation reader, and prompt
   byte decoding. Input routers stay per adapter because their decoders
   differ (TTY bytes against semantic keys).
5. **Derived data keyed by revision.** Fewer revisions, one per consumer
   behavior. The layout snapshot and accessibility tree are cached by
   revision; `captureVersion`, the TUI compositor rebuild and the chrome clear
   stop recomputing unchanged input.

   Done: `Projection.layout` carries the model's cached snapshot to every GUI
   renderer; the TUI compositor rebuilds only when invalidated; GUI focus is
   reconciled once per `update`, so native text and accessibility queries no
   longer mutate state; change review keeps its own session revision instead
   of bumping `chrome` (which also resent the client layout on every review
   event); `captureVersion` reads the chrome counter directly. Frontend
   benchmark medians match or beat the branch base. Kept on purpose: the
   `Version` fields, because 124 test assertions and the commit validations
   (sidebar, host, activation) depend on the individual counters and merging
   them buys no measured time; the accessibility tree, which is built only
   when the platform asks and whose widget registry is re-presented every
   frame anyway; and the TUI chrome repaint while toasts show, which must
   redraw the overlay over freshly composed pane cells.
6. **The runtime.** `RuntimeModel` tables for clients, workspaces, panes,
   attachments and agents. One flush after `update` (bug 3). Change-review
   discovery keyed by revision, `HOME` read once, an observer mask per pane
   instead of client scans. `application/commands`, the identical `*Failure`
   types, the proxy scheduling contexts and the empty event-dispatcher stubs
   go. Done: `Application` merged into `RuntimeModel`; `Runtime.update`
   routes every event and client request straight to flow procedures and
   ends with one `client_delivery.flush` (bug 3, with a regression test);
   `commands/`, `queries/`, `entrypoints/`, `event_dispatcher/` and the
   request contexts are gone; workspaces are one `Workspaces` table with the
   geometry lease as a column; the agent repository is indexed by pane id and
   the agent snapshot is projected once per flush from table revisions;
   `HOME` is read once; `Pane.observers` masks which clients a pane visits;
   change-review discovery is keyed by an owner stamp. Pending: attachments
   are still one store per client session rather than a runtime table; the
   proxy service keeps its lifecycle port, whose fakes prove its
   cancel-close-destroy order; panes still borrow `io`, `gpa` and history
   services because their actors run on worker threads.
7. **Sweep.** Remaining one-use types fold into their owners, `*Type` aliases
   disappear, and flow documents get their new call chains.

Slice 6 does not depend on the client slices and can run in parallel.
