# Configuration reload

One client owns one live Lua generation, compiled input router, plugin registry
and trust store. A reload constructs their complete replacement off the event
loop. The active objects change only after validation succeeds.

## End-to-end path

```text
changed config, module, plugin or trust fingerprint
  -> config_reload.wait on the worker
  -> AttachedClient.completeConfigReload
       config_reload.resolve validates and transfers or releases loaded resources
       unchanged: keep current state
       rejected: replace diagnostic and publish failure notification
       adopted: private adoptConfiguration
                  commit model and clear diagnostic
                  swap generation, registry, trust and input bindings
                  release old owners; update bars, appearance and geometry
                publish success notification
       scheduleConfigReload rearms the watcher

next presentation observation -> Presenter compares model versions
```

`client_startup` asks `AttachedClient.scheduleConfigReload` to start the watcher
after initiating runtime reads; the GUI schedules it from `GuiClient.start`
after bootstrap. The owner selects the current generation, plugin registry and
paths, then calls `config_reload.schedule` with explicit arguments. No configured
path means no watch; missing required resources return `ConfigurationNotLoaded`.
`AttachedClient.completeConfigReload` asks the same owner to rearm after every successfully
handled outcome. The worker loads a new Lua VM,
typed snapshot, plugin registry and trust store without touching the active
client. `config_reload.resolve` checks the sidebar
renderer against host capabilities, compiles the input router, clears the
worker's orphan slots and transfers one `Adoption` to `AttachedClient`. Rejection
frees all three owned objects in one place. The client applies the corresponding
model changes, resource transfer, notification and watcher scheduling.

The native adapter adds font preparation before delivering the result to
`AttachedClient.completeConfigReload`. `gui/ConfigurationReload` stages resources off-thread,
waits for native consumers to release the old frame, then adopts the generation
and prepared font together. Missing fonts reject the candidate through the
existing diagnostic flow. An unchanged watch does not request a frame. See
[native appearance](native-appearance.md#hot-reload) for viewport races,
resource retirement and shutdown ownership.

## Model transaction

`AttachedClient.synchronizeBars` selects bar sources only when Lua and the model
agree on their generation. Bar state receives the generation, sources and time;
its `rearm(io, timers)` method owns timer reservation and failure recovery.
The native timer port binds directly to `NativeLoop`. No bar scheduler receives
`AttachedClient`, and synchronization preserves any in-flight command identity.

`ClientModel` stores the active configuration generation. It accepts only a
newer generation and commits sidebar visibility, pane gaps and the typed bar
layout in the same
infallible transition. Every accepted generation advances
`Version.configuration`. A changed sidebar also advances `Version.chrome`; a
changed pane-gap preference updates every current tab and advances
`Version.panes`. Repeated semantic values do not advance those narrower
versions.

The model also owns the diagnostic banner and `Version.diagnostic`.
`AttachedClient.completeConfigReload` sends a rejected generation through
`client_diagnostic.replace`, which validates that bounded text and applies an
explicit safe fallback for malformed worker output without changing the active
generation. It then constructs the failure notification from the committed
banner. An accepted generation clears an older diagnostic with `model.clearDiagnostic` immediately after its semantic commit and before concrete resources
are adopted.

`AttachedClient.completeConfigReload` owns the top-level outcome order. An unchanged
attempt only rearms. A rejection commits and publishes its diagnostic before
rearming. An adoption commits the new state, delivers dependent resources, publishes
success and then rearms. `AttachedClient.completeConfigReload` owns the synchronous adoption order: after the
model commit and diagnostic clear, it adopts concrete resources, projects
appearance, configures sidebar resources and chooses exactly one sidebar or
pane-gap geometry branch. The pane-gap branch explicitly invalidates graphics
placements before offering active pane geometry with direct operation calls.
A sidebar change takes precedence when the same generation also changes pane
gaps because its shared projection already performs both operations. A stale
generation clears no diagnostic, invokes no effect, and `AttachedClient.adoptConfiguration`
releases the unaccepted adoption instead of leaking its VM or plugin objects.

## Ownership and effects

The operation swaps the generation, registry and trust store, then uses host
ports to adopt the input router and resolved sidebar renderer. It replaces sound policy through `sound.Playback.configure`, marks
the adoption consumed and destroys the previous owned objects. It is
infallible, so any later failure cannot leave the new semantic generation
without its concrete owners. The client event loop cannot interleave another
event during this synchronous operation. When the bar layout changed, the next
stage replaces its tick deadlines against the newly owned generation. A
failure to arm that scheduler retains the committed generation and layout;
stale command completions still fail their generation check.

Theme, icon and sidebar resources are updated after the ownership swap. CLI
theme and sidebar-renderer locks still override reloaded values. A sidebar or
pane-gap change invalidates host graphics placements and re-offers the current
pane geometry to the runtime. Sidebar changes pass through
`AttachedClient.deliverSidebarLayout`, the same
commit validation used by explicit toggles. `AttachedClient.adoptConfiguration`
owns resource transfer and the ordering of physical effects. The pane-gap branch selects the active tab, when present, and calls
`AttachedClient.resizeAttachedPanes` with its model and the current area.

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

## Validation

- `src/client/resources/config_reload.zig` owns rejected-load cleanup and the
  asynchronous handoff of generation, registry and trust ownership.
- `src/model/state/Model.zig` validates generation ordering and commits settings.
- `src/client/AttachedClient.zig` performs the resource transfer and physical
  effects, preserving the adopted generation after a downstream failure.
- `src/frontend/client/tests/configuration.zig` exercises reload outcomes,
  ownership replacement, stale cleanup, geometry failure and presentation.
- `src/gui/tests/configuration.zig` covers real file watches, font preparation,
  native frame boundaries, rejected candidates and shutdown ownership.
