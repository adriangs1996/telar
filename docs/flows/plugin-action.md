# Plugin action

This flow starts when input routing produces a configured plugin action. The
client resolves one immutable invocation, runs it outside the client process,
and accepts its bounded semantic effect batch only while the originating
configuration is still current.

## Overview

```text
configured plugin action
        |
applyInputDecision / applyDecision
        |
AttachedClient.executeAction
        |
plugin_actions.start
        |
ClientModel.beginPluginExecution { id, configuration_generation }
        |
Io.Select.concurrent -> isolated one-shot worker
        |
plugin_actions.start
        |
ClientEvent.plugin_result { execution_id, result }
        |
plugin_actions.complete
        |
finish exact id -> reject stale generation -> authorize whole batch
        |
AttachedClient.executeAction -> focused client use cases
        |
ClientModel / bounded runtime outbox
        |
plugin_actions.complete
        |
loop directive or diagnostic + notification
        |
presentation_lifecycle.observe -> Presenter
```

## Start ownership and order

`AttachedClient.executeAction` calls plugin_actions.start after prompt authority has
accepted the configured action. It does not resolve a package, reserve model
state or schedule work.

`plugin_actions.start` adapts the configured stable plugin and action IDs to
`plugin_actions.start`. The operation owns this order:

1. suppress a second invocation while one execution is active;
2. resolve the action and build its worker request;
3. reserve a monotonically increasing execution identity in `ClientModel`;
4. capture the current configuration generation in that reservation;
5. schedule the worker with the same identity.

Resolution happens before the reservation, so an unavailable registry or an
invalid action leaves the model idle. If worker scheduling fails after the
commit, `errdefer` removes only that exact reservation. The event loop remains
the sole writer of `ClientModel`; the worker receives copied request data and
returns through `ClientEvent.plugin_result`.

`plugin_actions.start` handles preparation and the resulting outcome in the
same concrete operation. Active, busy and unavailable outcomes stay quiet. An
invalid configured action commits a bounded diagnostic and publishes its failure
notification. Registry resolution and actual worker scheduling are called
directly. Unexpected preparation or scheduling errors propagate.

The execution reservation is lifecycle state, not render state. Beginning or
finishing it does not advance `ClientModel.Version` and cannot schedule an
empty frame.

## Completion ownership and order

The completion event retains the execution identity even when the worker
failed. `plugin_actions.complete` first consumes only a matching active
identity. An unknown completion cannot clear newer work. It then compares the
captured configuration generation with the current model generation.

A reload does not cancel a worker whose event is already in flight. Its result
becomes stale instead: the matching reservation is consumed, but the old batch
cannot be authorized or applied against the replacement configuration.

For a current successful result, the operation re-resolves authority through the
current `Registry.authorizeBatch`. That check verifies package position,
stable plugin ID, exact digest, declared capabilities and digest-bound grants
for every effect before any effect runs. After authorization, the completion
operation clears an obsolete diagnostic before applying the batch.

The same function handles the resulting outcome.
`plugin_actions.complete` maps `exit` to the client-loop exit
directive, keeps applied and obsolete outcomes quiet, and sends worker or
authorization failures through `client_diagnostic.replace`. It then builds a
bounded notification from the committed banner and calls
`AttachedClient.publishNotificationNow` after consuming the execution.

Authorized effects enter `AttachedClient.executeAction`, the shared dispatcher for
native semantic actions regardless of whether they came from host input, Lua
or a plugin. It delegates to the existing focused use cases. Those use cases
commit `ClientModel` or enqueue bounded runtime messages; they do not ask the
presenter to draw. After the event returns, `presentation_lifecycle.observe` lets the
presenter compare versions and schedule at most the required paced frame.

## Bounds and failure semantics

- The model permits one plugin execution at a time and stores one fixed-size
  identity plus its configuration generation.
- Worker execution retains the existing memory, instruction, wall-time,
  output and process-isolation bounds described in `docs/plugins.md`.
- `EffectBatch` has a fixed maximum and cannot contain Lua callbacks,
  expressions or another plugin invocation.
- Authorization covers the complete batch before application. Effect
  application is sequential, not transactional: a later runtime outbox error
  is returned after any earlier committed effect.
- A worker error, denial or rejected action reports through notification model
  state and `Version.diagnostic`. It does not mutate presenter-owned state
  directly.
- Client shutdown cancels outstanding select work and then destroys the
  disposable model, so no plugin execution must survive the client.

## Validation

- `src/client/model/Model.zig` proves single-flight reservation, exact
  identity matching, generation retention and identifier exhaustion.
- `src/client/application/input/plugin_action.zig` proves prepare/commit/
  schedule order, rollback, stale suppression, completion ordering, diagnostic
  clearing and failure classification before delivery.
- `src/client/application/input/plugin_action_delivery.zig` proves loop
  directives, diagnostic policy, notification mapping and retained diagnostics
  after publication failure.
- `src/client/application/configuration/client_diagnostic.zig` proves the shared
  diagnostic replacement and clear policy used by plugin outcomes.
- `src/client/application/input/action_routing.zig` proves that configured
  plugin values select only the asynchronous start port.
- `src/frontend/client/tests/` proves authorized application through
  presenter observation, stale-result suppression, capability denial, worker
  failure, unmatched identities, and busy and rejected start behavior on a
  real client.
- `src/client/plugins/plugins.zig` proves digest-bound capability checks and
  rejects invalid or recursive effect batches.
