# Agent done

A turn that finishes while nobody is looking is the state a user with several
panes needs first. The runtime reports it as `done` and keeps it there until a
client with that pane focused acknowledges it. `ready` means finished or
waiting and seen; `blocked` always wins over both.

## End-to-end path

```text
runtime evidence: projected working -> evidence ready
        |
Agent.visibleStatus  (seen = false)  -> AgentStatus.done
        |
Tracker revision -> Delivery.prepare -> schema.agent_sound (working -> done)
                                     -> schema.agent_snapshot
        |
agent_snapshot.applyAgentSnapshot -> ClientModel.reconcileAgentSnapshot
        |
pane_attachment.synchronizePaneAttachments
        |
ClientModel.takeAgentAcknowledgement  (focused pane, status done, once)
        |
model.to_runtime.push(acknowledge_agent) -> schema.AcknowledgeAgent
        |
Runtime.update -> client_connection.receive -> client_request.receive -> agent_done.acknowledge
        |
Tracker.acknowledge -> Agent.acknowledge (seen = true) -> reproject -> ready
        |
next agent_snapshot -> sidebar shows ready
```

## Runtime

`Agent.visibleStatus` runs inside `reproject`. When the previous projection was
`working` and the chosen evidence is `ready`, the aggregate clears `seen` and
projects `done`. Any evidence status other than `ready` restores `seen`, so
the next completion is reported again. Evidence precedence, expiry and
authority are untouched: `done` is a presentation of `ready`, never a new
evidence source.

`Tracker.acknowledge` resolves the exact pane generation. An unknown or stale
generation returns `unknown_agent` and the concrete runtime operation counts it as a stale
client message. An agent that is already seen returns `unchanged` and the
revision does not move. Only a real transition reprojects and bumps the
revision that delivery uses to send the next snapshot.

The sound decision keeps its shape: `soundForTransition` treats `working ->
done` exactly as it treated `working -> ready`. A `working -> ready` transition
no longer occurs in projections, because a completion is unseen by definition
until a client says otherwise.

## Client

Focus is client state and never becomes runtime truth, so the acknowledgement
is an explicit request rather than something the runtime infers from
`update_client_layout`. `ClientModel.takeAgentAcknowledgement` resolves the
focused pane of the active tab to its agent and returns the key once per
completion. `acknowledged_agent` is operational state with no presentation
revision; it resets when the same agent leaves `done`, so a later completion is
acknowledged again.

`pane_attachment.synchronizePaneAttachments` asks the model
first and queues `acknowledge_agent` before touching the attachment shelf. Every path that can change which pane the user is looking at already
enters this operation: pane focus, tab and workspace transitions, frames and
agent snapshots. It enqueues `schema.AcknowledgeAgent` on the fixed
`model.to_runtime` outbox; the request has no response.

Alerts follow the semantic: `done` publishes the success notification that
`ready` used to publish, and the flip back to `ready` after acknowledgement is
silent.

## Validation

- `src/backend/history/observer_support.zig` replays quoted status text, every byte
  boundary of a synchronized Codex redraw, unchanged ready repaints, and
  input-only batches.
- `src/backend/history/codex_screen.zig` covers drafts, cursor ownership,
  remapped interrupt keys, and disabled animations without consulting colors.
- `src/backend/runtime/tests/observation_events_test.zig` combines PTY
  frames with continuing Stop hooks and proves exactly one final sound. It
  also rejects a delayed ready result older than the current report.
- `src/backend/agent/tracker_tests.zig` covers active work versus settlement,
  monotonic ordering within a millisecond, stale evidence expiry, and model
  responses that finish before the agent turn, including Pi tools running
  beyond the report lifetime.
- `node --test src/cli/integration/pi.test.mjs` exercises serialized delivery,
  long-run renewal, nested dialogs, hung hooks, queue saturation, missed
  settlement and shutdown.

- `src/backend/agent/Agent.zig` proves the unseen window and its reset.
- `src/backend/runtime/tests/requests_test.zig` proves the
  request-to-tracker path, idempotence, stale generations and re-arming
  after a new turn.
- `src/backend/runtime/agent_done.zig` contains the direct
  acknowledgement operation and stale accounting.
- `src/core/schema_contract_test.zig` pins the `acknowledge_agent` bytes.
- `src/model/state/tests/observations.zig` proves once-per-completion
  acknowledgement and its reset.
- `src/client/panes/pane_attachment.zig` enqueues acknowledgement
  before attachment synchronization; client notification/agent integration
  tests exercise the operation against the real model and outbox.
