# Plugin action

This flow starts when input routing produces a configured plugin action. The
client resolves one immutable invocation, runs it outside the client process,
and accepts its bounded semantic effect batch only while the originating
configuration is still current.

## Overview

```text
configured plugin action
        |
host_inputs.applyDecision / GuiClient.applyInputDecision
        |
AttachedClient.executeAction
        |
AttachedClient.startPluginAction
        |
Registry.resolve + Registry.workerRequest
        |
ClientModel.beginPluginExecution { id, configuration_generation }
        |
client.workers.start(.plugin) -> job_runner -> isolated one-shot worker
        |
client Message .plugin_result { execution_id, result }
        |
AttachedClient.update -> AttachedClient.completePluginAction
        |
finish exact id -> reject stale generation -> authorize whole batch
        |
AttachedClient.applyPluginBatch -> AttachedClient.executeAction
        |
ClientModel / model.to_runtime
        |
AttachedClient.reportPluginCompletion
        |
loop directive or publishPluginFailure (diagnostic + notification)
        |
presentation_lifecycle.observe -> Presenter
```

## Start ownership and order

`AttachedClient.executeAction` calls `AttachedClient.startPluginAction` after
prompt authority has accepted the configured action. It does not resolve a
package, reserve model state or schedule work.

`AttachedClient.startPluginAction` takes the configured stable plugin and action
IDs and owns this order:

1. suppress a second invocation while one execution is active;
2. resolve the action and build its worker request;
3. reserve a monotonically increasing execution identity in `ClientModel`;
4. capture the current configuration generation in that reservation;
5. start the `.plugin` job through `client.workers.start` with the same
   identity.

Resolution happens before the reservation, so an unavailable registry or an
invalid action leaves the model idle. If worker scheduling fails after the
commit, `errdefer` removes only that exact reservation through
`model.plugins.finishPluginExecution`. The event loop remains the sole writer
of `ClientModel`; the worker receives copied request data and returns as one
`.plugin_result` client `Message`.

`AttachedClient.startPluginAction` passes every outcome to `reportPluginStart`.
Active, busy and unavailable outcomes stay quiet. An invalid configured action
goes through `publishPluginFailure`, which commits a bounded diagnostic and
publishes its failure notification. Registry resolution and actual worker scheduling are called
directly. Unexpected preparation or scheduling errors propagate.

The execution reservation is lifecycle state, not render state. Beginning or
finishing it does not advance `ClientModel.Version` and cannot schedule an
empty frame.

## Completion ownership and order

The completion event retains the execution identity even when the worker
failed. `AttachedClient.completePluginAction` first consumes only a matching active
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

`AttachedClient.reportPluginCompletion` handles the resulting outcome. It maps
`exit` to the client-loop exit directive, keeps applied and obsolete outcomes
quiet, and passes worker or authorization failures to `publishPluginFailure`.
That procedure commits the banner through `client_diagnostic.replace`, builds a
bounded notification from it and calls `AttachedClient.publishNotificationNow`
after the execution was consumed.

`applyPluginBatch` sends authorized effects to `AttachedClient.executeAction`,
the shared dispatcher for native semantic actions regardless of whether they
came from host input, Lua or a plugin. It delegates to the existing focused
procedures. Those procedures commit `ClientModel` or push bounded messages into
`model.to_runtime`; they do not ask the presenter to draw. After the event returns, `presentation_lifecycle.observe` lets the
presenter compare versions and schedule at most the required paced frame.

## Bounds and failure semantics

- The model permits one plugin execution at a time and stores one fixed-size
  identity plus its configuration generation.
- Worker execution retains the existing memory, instruction, wall-time,
  output and process-isolation bounds described in `docs/plugins.md`.
- `EffectBatch` has a fixed maximum and cannot contain Lua callbacks,
  expressions or another plugin invocation.
- Authorization covers the complete batch before application. Effect
  application is sequential, not transactional: a later `model.to_runtime` error
  is returned after any earlier committed effect.
- A worker error, denial or rejected action reports through notification model
  state and `Version.diagnostic`. It does not mutate presenter-owned state
  directly.
- Client shutdown cancels outstanding inbox jobs and then destroys the
  disposable model, so no plugin execution must survive the client.

## Validation

- `src/model/state/tests/configuration_and_host.zig` proves single-flight
  reservation, exact identity matching, generation retention and identifier
  exhaustion.
- `src/client/input/plugin_action.zig` and
  `src/client/input/plugin_action_delivery.zig` hold the start and completion
  outcome types and the failure-publication mapping.
- `src/client/config/client_diagnostic.zig` proves the shared diagnostic
  replacement and clear policy used by plugin outcomes.
- `src/frontend/client/tests/configuration.zig` proves authorized application
  through presenter observation, stale-result suppression, capability denial,
  worker failure, unmatched identities, and busy and rejected start behavior on
  a real client.
- `src/client/plugins/plugins.zig` proves digest-bound capability checks and
  rejects invalid or recursive effect batches.
