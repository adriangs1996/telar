# Pane resource release

This flow starts after a canonical pane, tab or workspace transition reports
one retired pane identity. It ends after every client-owned authority and
physical graphics resource for that identity is gone.

## Boundary

`ReleasePaneResourcesHandler` owns retirement policy. It releases three exact
model-owned authorities in order:

1. copy mode;
2. a streamed pane paste;
3. reported child focus.

It then invokes one physical graphics effect. The concrete `pane_resources`
adapter wires that effect to `kitty.Store.clearPane`; it does not decide or
mutate `AppState` transitions.

```text
canonical pane retirement
        |
ReleasePaneResourcesHandler
        |
ClientModel.releaseCopyMode
        |
ClientModel.releasePanePaste
        |
ClientModel.releaseReportedPaneFocus
        |
pane_resources.clearGraphics -> kitty.Store.clearPane
```

Pane exit, tab removal, tab snapshot reconciliation, workspace reconciliation
and workspace departure all use this entrypoint. None needs to know which
input or reporting authority may still name the pane.

## Identity and presentation

Every release matches the stable pane identity. Retiring another pane preserves
the current copy, paste and focus owners. A repeated or unknown identity leaves
model state unchanged but still clears physical graphics, which repairs stale
client resources after partial reconciliation.

Copy-mode release advances its presentation revision. Paste and reported focus
are operational state and advance no display revision. A canonical transition
that changes visible state supplies the containing model revision; inactive or
repeated cleanup schedules no frame. This handler never schedules one.

Authoritative retirement forgets reported focus without sending focus-out. The
child has already exited or the client attachment is being discarded, so no
valid receiver remains. This handler matches one exact pane identity. A
canonical tab or workspace transition that invalidates the entire reporting
context uses the separate, effect-free `RetireReportedPaneFocusHandler`.

## Bounds and proof

The model policy performs constant work and allocates nothing. Graphics cleanup
scans only the existing bounded per-client image and placement stores.

- `ReleasePaneResourcesHandler retires exact pane authorities before graphics`
  proves paste, focus and copy cleanup through public model operations.
- `ReleasePaneResourcesHandler clears stale graphics for an unknown pane`
  proves repeated physical cleanup without model mutation.
- `tab reconciliation retires removed pane resources and continuations` proves
  exact copy and graphics cleanup through a canonical snapshot.
- Pane-exit, tab-removal, workspace-snapshot and handoff integration tests
  exercise the same adapter from their owning transitions.
