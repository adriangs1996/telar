# Shared model and geometry extraction

Validated on the phase-0 host, with Zig 0.16.0. No performance verdict is
claimed for this phase; paired measurements remain part of the final gate.

- The complete client model and its state transitions now live in `telar-client`.
  Navigation, workspaces, tabs, selection, editing, agents, notifications, bars,
  link targets, attachment identities and common configuration values moved with
  their tests. The TUI uses these implementations, not copies.
- Pane geometry has presentation-supplied border/gap measurements. Changing
  measurements invalidates geometry without changing serialized topology or
  proportions. Restoration keeps the current adapter measurements.
- TUI controllers take their workbench from a bounded, versioned region value.
  The host adapter publishes revisions when the region changes, including ABA.
  Pane layout snapshots retain their independent topology revision. TUI hit maps
  and pixel-to-grid conversion remain presentation responsibilities.
- Semantic host observations describe image availability, pointer coordinates,
  appearance and geometry. Kitty compression negotiation and unanswered-probe
  policy remain in the TUI; compression replies no longer revise the model.
  Existing terminal diagnostic JSON keys and Lua configuration syntax remain.
- `test-client`, `test-frontend`, schema/transport/isolation tests, semantic
  analysis, the diagnostics-enabled ReleaseFast build and client codestyle pass.
  Test logs are retained alongside this report. Shared tests link without the
  frontend module or its platform/graphics libraries. There are 246 shared-client
  tests and 1208 frontend tests in ReleaseSafe; the shared suite also passes in
  Debug.

One combined run failed the transport integration assertion `expected .crosshair,
found .text` in the two-client acknowledgement test. The isolated schema retry
passed. Both logs are retained; the intermittent result remains open for the
final gate rather than being reported as a clean first-run pass.

Application handlers, connection resources, graphics retention and presentation
completion remain the subjects of phases 3–5. Region revisions are available at
this boundary; they do not by themselves replace gesture ownership or enforce
asynchronous completion validity.
