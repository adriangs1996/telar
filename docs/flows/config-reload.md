# Configuration reload

One client owns one live Lua generation, compiled input router, plugin registry
and trust store. A reload constructs their complete replacement off the event
loop. The active objects change only after validation succeeds.

## End-to-end path

```text
config, local module, plugin or trust-store fingerprint changes
                            |
              config_reload.waitConfigReload
                            |
                  ConfigReload.loaded
                            |
                 config_reloads.handle
                            |
                 config_reload.resolve
                            |
              DeliverConfigReloadHandler
              |             |             |
          unchanged     rejected       adopted
              |             |             |
              |    ClientDiagnostic   ApplyConfigHandler
              |             |             |
              |    failure notice    model commit + clear
              |                           |
              |                resource and UI projection
              |                           |
              |                    success notice
              |             |             |
              +-------------+-------------+
                            |
                       watcher rearm
                            |
                  presentation_lifecycle.observe
                            |
                       Presenter
```

`client_startup` asks `config_reloads.schedule` to start the watcher after the
runtime handshake. `DeliverConfigReloadHandler` rearms it through an adapter
port after every successfully handled outcome. The worker loads a new Lua VM,
typed snapshot, plugin registry and trust store without touching the active
client. `config_reload.resolve` checks the sidebar
renderer against host capabilities, compiles the input router, clears the
worker's orphan slots and transfers one `Adoption` to the adapter. Rejection
frees all three owned objects in one place. The adapter translates that
physical result into an application resolution without deciding its effects.

## Model transaction

`ClientModel` stores the active configuration generation. It accepts only a
newer generation and commits sidebar visibility and pane gaps in the same
infallible transition. Every accepted generation advances
`Version.configuration`. A changed sidebar also advances `Version.chrome`; a
changed pane-gap preference updates every current tab and advances
`Version.panes`. Repeated semantic values do not advance those narrower
versions.

The model also owns the diagnostic banner and `Version.diagnostic`.
`DeliverConfigReloadHandler` sends a rejected generation through
`ClientDiagnosticHandler`, which validates that bounded text and applies an
explicit safe fallback for malformed worker output without changing the active
generation. It then constructs the failure notification from the committed
banner. An accepted generation clears an older diagnostic through the same
handler immediately after its semantic commit and before concrete resources
are adopted.

`DeliverConfigReloadHandler` owns the top-level outcome order. An unchanged
attempt only rearms. A rejection commits and publishes its diagnostic before
rearming. An adoption calls `ApplyConfigHandler`, publishes success and then
rearms. `ApplyConfigHandler` owns the synchronous adoption order: after the
model commit and diagnostic clear, it adopts concrete resources, projects
appearance, configures sidebar resources and chooses exactly one sidebar or
pane-gap geometry branch. A sidebar change takes precedence when the same
generation also changes pane gaps because its shared projection already
invalidates placements and re-offers geometry. A stale generation clears no
diagnostic, invokes no effect, and `config_reloads.apply` releases the
unaccepted adoption instead of leaking its VM or plugin objects.

## Ownership and effects

The application handler's first external stage asks the adapter to swap the
generation, registry, trust store, input router and resolved sidebar renderer.
That callback replaces sound policy through `sound.Playback.configure`, marks
the adoption consumed and destroys the previous owned objects. It is
infallible, so any later failure cannot leave the new semantic generation
without its concrete owners. The client event loop cannot interleave another
event during this synchronous operation.

Theme, icon and sidebar resources are updated after the ownership swap. CLI
theme and sidebar-renderer locks still override reloaded values. A sidebar or
pane-gap change invalidates host graphics placements and re-offers the current
pane geometry to the runtime. Sidebar changes pass through
`sidebar_projection.apply` and `DeliverSidebarVisibilityHandler`, the same
exact-commit delivery used by explicit toggles. `config_reloads` implements
each concrete port independently; it does not choose the outcome order,
notification content or layout branch. The pane-gap branch uses
`OfferActivePaneGeometryHandler`, so an empty projection and active-tab
selection remain application policy.

Fallible sidebar configuration, projection, geometry, notification or watcher
work does not roll back any earlier stage. If pane geometry cannot enter the
bounded outbox, the model, cleared diagnostic, new configuration owners and
appearance remain active, while success notification and rearm are skipped. A
notification failure retains an adopted generation or committed rejection but
also prevents rearm, matching the existing fail-fast lifecycle. A later
resize, reload or reconnect can repair disposable resources without reviving
the old Lua generation.

## Presentation

The config use case never requests a draw. After the event returns, the loop
publishes `ClientModel.Version`. `Presenter` compares configuration and
diagnostic revisions with the version it last painted, invalidates the view and
folds accepted changes into one paced frame. A rejection presents its
diagnostic without depending on the failure notification as an accidental draw
trigger.

## Proof

- `src/frontend/client/config_reload.zig` proves rejected-load ownership and
  owns asynchronous loading, validation and orphan cleanup.
- `src/frontend/client/model.zig` proves generation ordering, atomic semantic
  settings and isolated versions.
- `src/frontend/client/application/config_reload.zig` proves commit-before-
  resource ordering, diagnostic clearing, theme lock, mutually exclusive
  layout branches and every partial adoption failure boundary.
- `src/frontend/client/application/config_reload_delivery.zig` proves outcome
  branching, rejection fallback, notification policy, rearm ordering and every
  top-level partial failure boundary.
- `src/frontend/client/application/client_diagnostic.zig` proves diagnostic
  validation, fallback and idempotent clear policy shared with other producers.
- `src/frontend/client/config_reloads.zig` owns concrete resource transfer,
  physical effect adapters and watcher scheduling, without application
  branching.
- `src/frontend/client/application/sidebar_visibility_delivery.zig` owns exact
  sidebar commit validation and projection order.
- `src/frontend/client/sidebar_projection.zig` wires the shared physical
  sidebar projection ports.
- `src/frontend/client/client_test.zig` proves resolved delivery, ownership
  replacement, accepted diagnostic cleanup, stale cleanup, post-commit geometry
  failure and presenter-owned drawing.
