# Pane graphics

Pane graphics carry image resources and placements from the runtime's terminal
emulator to the host terminal. The runtime owns the canonical image identity,
generation, pixels and placement facts. The disposable client owns mapped
resources, host identifiers, clipping, visibility, transmission and the cell
fallback used when Kitty graphics are unavailable.

## Client boundary

```text
schema.graphics_*
       |
server_messages dispatcher
       |
pane_graphics adapter
       |
ReconcilePaneGraphicsHandler
       |
       +-- physical command --> kitty.Store
       |                              |
       |                    ingressVersion
       |
       +-- derived fallback --> ClientModel.setPaneGraphicsFallback
       |                              |
       |                    Version.pane_graphics
       |
       +-- revision break --> request_graphics_snapshot
       |
       +-- shared-map error --> configure_graphics(shared=false)
                                      |
                             request_graphics_snapshot

presentation_lifecycle.observe
       |
Presenter observes model version + graphics ingress version
       |
paced cell pass
       |
bounded media pass
```

`server_messages` only translates the decoded union variant into a typed
application command. `ReconcilePaneGraphicsHandler` applies the physical
resource first and then commits the fallback derived from the resulting store.
It does not request a draw.

`kitty.Store` remains outside `ClientModel`. It owns allocations, shared
memory mappings, quotas, host image identifiers and transmission damage. Every
accepted runtime graphics message advances `ingressVersion`. Stale deltas and
failed operations do not. The presenter observes that revision independently
from semantic model versions, so a supported host still schedules the cell
pass that must precede media work even when no fallback changes.

The fallback flag is semantic client state because cell composition reads it.
Only `ClientModel.setPaneGraphicsFallback` may change it. A real change
advances `Version.pane_graphics` and invalidates the owning tab composition;
unknown panes and repeated values are no-ops. Capability negotiation
reconciles all bounded panes through the same model operation.

## Ordering and recovery

A graphics revision break does not mutate the fallback. The handler asks for
one canonical pane graphics snapshot. Snapshot begin clears the physical pane
replica, image and placement messages rebuild it at one revision, and snapshot
end removes incomplete resources.

If a declared shared-memory image cannot be mapped, the client first sends
`configure_graphics(shared=false)` and then requests a snapshot. The runtime
therefore rebuilds the pane with bounded pixel chunks instead of repeating the
failed transport. Failure to enqueue the later snapshot does not undo the
already requested downgrade.

## Budget and bounds

Resource ingestion belongs to the media path. Images, chunks and placements
are bounded by the graphics schema and `kitty.Store` quotas. The presenter
always completes the cell pass first. Its separate media tick emits at most the
configured KGP byte budget and yields while interactive cell work is pending.
Repeated frames replace obsolete generations in the store rather than forming
an unbounded replay queue.

The socket dispatcher is still the decoded message entrypoint. This slice
separates ownership and scheduling policy; moving bulk ingestion behind a
dedicated media queue is a separate scheduling change.

## Proof

- `src/frontend/graphics/kitty.zig` proves quotas, revision recovery, stale
  suppression, snapshot validation and exact ingress versions.
- `src/frontend/client/model.zig` proves fallback ownership, no-op behavior,
  composition invalidation and isolated semantic versions.
- `src/frontend/client/application/pane_graphics.zig` proves resource-before-
  model ordering, recovery selection, downgrade ordering and failure policy.
- `src/frontend/client/client_test.zig` proves protocol recovery, physical-only
  presenter observation and shared-memory downgrade ordering.
- `src/frontend/client/presenter.zig` proves that use cases do not choose when
  to paint and that semantic and physical revisions fold into one paced frame.
