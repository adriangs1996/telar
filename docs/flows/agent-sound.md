# Agent sound

The runtime emits sound only when an agent moves from `working` to `ready` or
`blocked`. The client checks the exact pane generation and owns every
host-audio resource. A headless runtime never opens an audio device or starts
a playback command.

## End-to-end path

```text
runtime agent transition
        |
runtime Delivery.prepare
        |
schema.agent_sound
        |
server_messages dispatcher
        |
agent_sounds.apply
        |
HandleAgentSoundHandler
        |
ClientModel.knowsAgent
        |
sound.Playback.request
        |
ClientEvent.sound_played <- sound.play host worker
        |
agent_sounds.handlePlayed
        |
sound.Playback.complete
```

The runtime message carries a pane ID, pane generation and semantic sound
kind. `agent_sounds.apply` translates that identity into an `AgentKey`.
`HandleAgentSoundHandler` schedules playback only when the current client
replica contains the exact key. A delayed message for an earlier process
cannot make noise after the numeric pane ID has been reused.

The handler reads `ClientModel` but does not mutate it. Accepted, stale and
configuration-filtered sounds leave every model version unchanged. The
client loop can still call `Client.observeModel` after dispatch; the presenter
sees no revision and schedules no frame.

## Playback ownership and bounds

`sound.Playback` owns the effective `SoundConfig`, one active worker token and
one optional queued `AgentSound`. `Client` holds that object but knows none of
its queue transitions. The adapter starts workers through the client select
and delegates every completion back to `agent_sounds.handlePlayed`.

The queue has fixed depth. A request starts immediately when no worker is
active. Further requests fold into the one queued value. `needs_input` wins
over `ready`, since an unanswered prompt should not be hidden by a later
completion sound. Repetition cannot increase memory use or process count.

A validated configuration adoption calls `Playback.configure`. New requests
use the replacement policy immediately, and queued work forbidden by that
policy is discarded. The player does not cancel a host command that already
started. Its completion still releases the worker token, but no forbidden
successor starts.

## Worker and recovery

Playback runs on the observation path. macOS uses `/usr/bin/afplay`. Linux
tries a fixed sequence of common players, and Windows calls `MessageBeep`.
External commands have a three-second timeout and retain at most 4096 bytes
from each output stream. At most one command belongs to a client at a time.

A worker error drops that sound. The completion handler releases its token and
continues with the coalesced successor, so one missing player cannot wedge the
queue. Failure to add a worker to the client select releases the reserved
token and propagates the scheduling error.

Client teardown cancels its select tasks. A reconnect constructs a fresh
`Playback`; it neither restores nor replays old audio work. Runtime agent state
continues independently and later exact sound events may start a new queue.

## Proof

- `src/frontend/sound/types.zig` proves per-kind policy filtering.
- `src/frontend/sound/playback.zig` proves one active token, one coalesced
  successor, priority, configuration replacement and scheduling failure
  recovery.
- `src/frontend/sound/worker.zig` owns the bounded host adapters; the cross
  build compiles the Linux and Windows paths.
- `src/frontend/client/application/agent_sound.zig` proves exact-identity
  gating, stale suppression and effect-error propagation.
- `src/frontend/client/agent_sounds.zig` owns protocol translation, worker
  scheduling and the completion entrypoint.
- `src/frontend/client/client_test.zig` proves wire identity, bounded queuing,
  unchanged model and presentation versions, and configuration adoption.
- `src/backend/runtime/root.zig` proves the exact transition policy and adds
  the pane generation used by the client gate.
