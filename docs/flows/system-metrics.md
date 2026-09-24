# System metrics

The runtime samples the host where agents execute. Each disposable client
stores only the latest bounded replica and presents it through configured bar
sources. The view owns no second semantic copy.

## End-to-end path

```text
runtime system_metrics.tick -> observability Sampler (worker)
             |
system_metrics.finish -> model.system_metrics
             |
runtime Delivery.prepare
             |
schema.system_metrics
             |
runtime_messages.handleServerMessage
             |
system_metrics.reconcile
             |
SystemMetrics + Version.system_metrics
             |
presentation_lifecycle.observe
             |
Presenter -> view render(Projection.system_metrics, bars)
             |
configured metrics source or dynamic callback context
```

The sampler runs as a job started by the runtime metrics tick, outside the
interactive path. It
keeps only the latest CPU percentage, used memory in tenths of a GiB and an
optional battery percentage. Its revision advances only when those visible
values change.

`Delivery.prepare` compares that revision with a per-client delivery cursor.
A connected client receives the newest values, not a replay of intermediate
samples. A host without a supported battery source sends an absent battery,
which the metrics source omits.

## Client transaction

`runtime_messages.handleServerMessage` translates the validated protocol message
into the client domain value and calls `system_metrics.reconcile`,
which has no view or presenter dependency.

`ClientModel` is the sole owner of the client replica. Revision zero and newer
out-of-range percentages are rejected. Equal or older revisions are no-ops.
An accepted newer value replaces `model.system_metrics` and advances
`model.system_metrics_revision`, reported as `Version.system_metrics`, exactly
once. Rejection preserves the last usable
metrics and every model version.

## Presentation and recovery

The protocol dispatcher never requests a draw. After event dispatch,
`presentation_lifecycle.observe` publishes the complete model version. `Presenter`
compares `Version.system_metrics` with the version it last painted, invalidates
the view when it changed and passes `Projection.system_metrics` into the next
paced frame. `telar.bar.metrics()` renders that value in any permitted slot;
dynamic and command render callbacks receive the same snapshot under
`ctx.metrics`. Several samples observed within one frame interval fold into one
render of the latest values.

The view converts that immutable render input into the status-bar presentation
shape without storing it. Formatting uses fixed buffers and allocates nothing
on the frame path. A reconnect starts with an empty disposable model and the
runtime's fresh delivery cursor supplies the current sample.

## Validation

- `lib/hostmetrics/system_metrics.zig` proves bounded sampling, visible
  change detection and platform value reduction.
- `src/backend/runtime/delivery/` proves per-client latest-state delivery.
- `src/core/schema/schema.zig` proves wire validation and optional-battery
  encoding rules.
- `src/model/state/tests/observations.zig` proves ownership, stale handling,
  validation, isolated versioning and retained state after rejection.
- `system metrics commit before presenter-owned projection` in
  `src/frontend/client/tests/notifications_and_agents.zig` proves protocol
  adaptation, absence of direct draw requests and presenter-owned status-bar
  projection.
