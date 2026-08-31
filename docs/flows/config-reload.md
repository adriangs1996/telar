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
              Client.handleConfigReloadEvent
                            |
                 config_reloads.handle
                            |
                  config_reload.resolve
                            |
                  ApplyConfigHandler
                            |
             ClientModel.applyConfiguration
                            |
        generation, router and plugin ownership swap
                            |
       view appearance and pane geometry synchronization
                            |
                 success notification
                            |
                  Client.observeModel
                            |
                       Presenter
```

The worker loads a new Lua VM, typed snapshot, plugin registry and trust store
without touching the active client. `config_reload.resolve` checks the sidebar
renderer against host capabilities, compiles the input router, clears the
worker's orphan slots and transfers one `Adoption` to the adapter. Rejection
frees all three owned objects in one place. A load or validation failure keeps
the previous generation active and publishes its bounded diagnostic through
`ClientModel`.

## Model transaction

`ClientModel` stores the active configuration generation. It accepts only a
newer generation and commits sidebar visibility and pane gaps in the same
infallible transition. Every accepted generation advances
`Version.configuration`. A changed sidebar also advances `Version.chrome`; a
changed pane-gap preference updates every current tab and advances
`Version.panes`. Repeated semantic values do not advance those narrower
versions.

The model also owns the diagnostic banner and `Version.diagnostic`. A rejected
generation replaces that bounded text without changing the active generation.
An accepted generation clears an older diagnostic during the resource swap.

`ApplyConfigHandler` invokes the concrete effect only after this commit. A
stale generation invokes no effect, and `config_reloads.apply` releases the
unaccepted adoption instead of leaking its VM or plugin objects.

## Ownership and effects

The adapter's first post-commit operation swaps the generation, registry,
trust store, input router and resolved sidebar renderer. It replaces sound
policy through `sound.Playback.configure`, then destroys the previous owned
objects. The client event loop cannot interleave another event during this
synchronous operation.

Theme, icon and sidebar resources are updated after the ownership swap. CLI
theme and sidebar-renderer locks still override reloaded values. A sidebar or
pane-gap change invalidates host graphics placements and re-offers the current
pane geometry to the runtime. The adapter publishes the success notification
last.

Fallible resource work does not roll back either commit. If pane geometry
cannot enter the bounded outbox, the model and all new configuration owners
remain active. A later resize, reload or reconnect can repair disposable
resources without reviving the old Lua generation.

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
  effect ordering and retained commits after effect failure.
- `src/frontend/client/config_reloads.zig` owns the concrete resource and
  configuration-object swap.
- `src/frontend/client/client_test.zig` proves ownership replacement, stale
  cleanup, post-commit geometry failure and presenter-owned drawing.
