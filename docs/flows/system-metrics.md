# System metrics

The runtime samples the host where agents execute. Each disposable client
stores only the latest bounded replica and presents it through configured bar
sources. The view owns no second semantic copy.

## End-to-end path

```text
runtime system_metrics.Sampler
             |
runtime Delivery.prepare
             |
schema.system_metrics
             |
server_messages dispatcher
             |
system_metrics adapter
             |
ReconcileSystemMetricsHandler
             |
ClientModel.reconcileSystemMetrics
             |
SystemMetrics + Version.system_metrics
             |
presentation_lifecycle.observe
             |
Presenter -> View.render(system_metrics, bars)
             |
configured metrics source or dynamic callback context
```

The sampler runs on the runtime metrics tick, outside the interactive path. It
keeps only the latest CPU percentage, used memory in tenths of a GiB and an
optional battery percentage. Its revision advances only when those visible
values change.

`Delivery.prepare` compares that revision with a per-client delivery cursor.
A connected client receives the newest values, not a replay of intermediate
samples. A host without a supported battery source sends an absent battery,
which the metrics source omits.

## Client transaction

`system_metrics.apply` translates the validated protocol message into the
client domain value. `ReconcileSystemMetricsHandler` delegates the transition
to `ClientModel`; it has no view or presenter dependency.

`ClientModel` is the sole owner of the client replica. Revision zero and newer
out-of-range percentages are rejected. Equal or older revisions are no-ops.
An accepted newer value replaces the replica and advances
`Version.system_metrics` exactly once. Rejection preserves the last usable
metrics and every model version.

## Presentation and recovery

The protocol dispatcher never requests a draw. After event dispatch,
`presentation_lifecycle.observe` publishes the complete model version. `Presenter`
compares `Version.system_metrics` with the version it last painted, invalidates
the view when it changed and passes `ClientModel.systemMetrics()` into the next
paced frame. `telar.bar.metrics()` renders that value in any permitted slot;
dynamic and command render callbacks receive the same snapshot under
`ctx.metrics`. Several samples observed within one frame interval fold into one
render of the latest values.

`View` converts that immutable render input into the status-bar presentation
shape without storing it. Formatting uses fixed buffers and allocates nothing
on the frame path. A reconnect starts with an empty disposable model and the
runtime's fresh delivery cursor supplies the current sample.

## Proof

- `src/backend/runtime/system_metrics.zig` proves bounded sampling, visible
  change detection and platform value reduction.
- `src/backend/runtime/delivery.zig` proves per-client latest-state delivery.
- `src/core/schema/root.zig` proves wire validation and optional-battery
  encoding rules.
- `src/frontend/client/model.zig` proves ownership, stale handling, validation
  and isolated versioning.
- `src/frontend/client/application/system_metrics.zig` proves the use-case
  boundary and retained state after rejection.
- `src/frontend/client/client_test.zig` proves protocol adaptation, absence of
  direct draw requests and presenter-owned status-bar projection.
