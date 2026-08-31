# Pane metadata

The runtime publishes a pane's current working directory and observed
foreground process independently from its cell frames. Each client stores a
bounded replica for the lifetime of that pane. Foreground changes update pane
borders; CWD changes retain the exact path and publish presentation work only
when its bounded display name changes.

## End-to-end path

```text
runtime Pane.cwd / foreground process cache
                    |
Attachment.prepareCwd / prepareForeground
                    |
schema.pane_cwd / schema.pane_foreground
                    |
server_messages dispatcher
                    |
pane_metadata adapter
                    |
UpdatePaneMetadataHandler
                    |
ClientModel.updatePaneMetadata
                    |
multiplexer.Model.setPaneCwd / setPaneForeground
                    |
ClientModel.Version.pane_metadata
          + optional Version.pane_foreground
                    |
Presenter.observeModel -> paced presentation
```

The runtime owns both facts. `Pane.cwd` tracks the latest verified directory,
and the process observer owns the bounded foreground name. Each runtime
attachment records which revisions it delivered, so a new client or a
reconnected client receives the current values without making client state
authoritative.

`pane_metadata` translates the two protocol messages into one application
command. `UpdatePaneMetadataHandler` delegates the transaction to
`ClientModel`. Neither layer reaches into pane storage, view state, composition
caches or the presenter.

## Model transaction

`ClientModel.updatePaneMetadata` resolves the pane before mutation. A report
for a retired pane and an exact repeated value are no-ops. The model calls the
multiplexer through `setPaneCwd` or `setPaneForeground`; callers outside the
workspace capability no longer mutate `Pane` storage directly.

CWD storage owns an allocated copy bounded by `schema.max_cwd_bytes`. A change
to another path with the same bounded basename still commits the exact path,
but advances no presentation revision. A changed display name advances
`Version.pane_metadata` once.

Foreground storage uses the pane's fixed
`schema.max_foreground_name_bytes` buffer. A changed name advances both
`Version.pane_metadata` and `Version.pane_foreground`. The first revision tells
the presenter that client metadata changed. The second identifies the subset
that affects pane composition.

The model and multiplexer do not invalidate view or composition caches. The
returned commit contains pane identity, metadata kind, whether the display
projection changed and both committed revisions.

## Presentation

After the server event, the client loop calls `Client.observeModel`. No
metadata handler calls `requestDraw`.

`Presenter.presentDue` maps the metadata revision to client-view invalidation.
A foreground revision also invalidates every bounded tab composition before
rendering the active tab. Invalidating all tab compositions is intentional:
several foreground reports can fold into one 60 Hz presentation, and an
inactive tab must not retain a border composed from an older process name.

An exact repeat or a CWD move that retains the same display name publishes no
revision, schedules no frame and performs no cache work.

## Failure and recovery

Allocating a replacement CWD happens before the old value is released. An
allocation failure preserves the previous path and both revisions. Foreground
updates allocate nothing.

Pane retirement frees the CWD copy with the rest of the disposable pane.
Reports that arrive after retirement are ignored. Reconnection creates fresh
runtime attachment cursors, which publish the runtime's current CWD and
foreground revisions again.

## Proof

- `src/frontend/workspace/multiplexer.zig` proves bounded CWD display names,
  exact path ownership, fixed foreground storage and border composition.
- `src/frontend/client/model.zig` proves stale and repeated reports, exact
  revision changes, state-only CWD moves and allocation failure behavior.
- `src/frontend/client/application/pane_metadata.zig` proves both messages use
  the same model transaction.
- `src/frontend/client/client_test.zig` proves the dispatcher commits before
  presentation, requests no direct draw and leaves cache invalidation to the
  presenter.
- `src/backend/runtime/attachment.zig` proves per-client delivery cursors for
  both runtime-owned facts.
