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

| Metric | Baseline |
| --- | --- |
| First-party Zig files under 20 lines | 1,618 of 3,000 |
| `context: *anyopaque` ports | 192 fields in 82 files |
| `TerminalClient.of` / `GuiClient.of` uses (production) | 157 / 24 |
| Fields in the client `Version` | 27 |
| Key press to pane input, TUI / GUI | ~26 hops in 10 files / ~36 in 14 |
| PTY bytes to client frame, runtime | ~20 hops in ~24 files |
| `LayoutSnapshot` rebuilds per GUI frame | 5 fixed, plus one per notification and one per pump |

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
   `docs/flows/client-event-dispatch.md`.

## Slices

1. **Rules and tooling.** Done in this change: the architecture, naming,
   invariants and source-layout documents; five-parameter limit; private
   helper types in their owner file; capability lists removed from the client
   boundary checker. Pending: a codestyle rule that method receivers are
   named `self`, with an automatic fix. It runs after slices 2 and 3 turn most
   of today's methods into procedures that take `model`.
2. **Tabs, panes and layouts in the client.** Flat `Tabs`, `Panes` and
   `Layouts` tables with a pane index replace `TabsModel`, `Tab`,
   `MultiplexerModel` and their per-tab pane arrays. Removes the three lookups
   in `applyPaneFrame` and the eleven `tabForPane` plus `find` pairs. Agent-only
   pane fields move to an `agents` table. `pane_frame.receive` is the first
   flow written with the new names.
3. **The rest of the client model.** The sixteen `data.*` fields beside
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
5. **Derived data keyed by revision.** Fewer revisions, one per consumer
   behavior. The layout snapshot and accessibility tree are cached by
   revision; `captureVersion`, the TUI compositor rebuild and the chrome clear
   stop recomputing unchanged input.
6. **The runtime.** `RuntimeModel` tables for clients, workspaces, panes,
   attachments and agents. One flush after `update` (bug 3). Change-review
   discovery keyed by revision, `HOME` read once, an observer mask per pane
   instead of client scans. `application/commands`, the identical `*Failure`
   types, the proxy scheduling contexts and the empty event-dispatcher stubs
   go.
7. **Sweep.** Remaining one-use types fold into their owners, `*Type` aliases
   disappear, and flow documents get their new call chains.

Slice 6 does not depend on the client slices and can run in parallel.
