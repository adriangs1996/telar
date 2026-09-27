# Agent sound

The runtime emits sound only when an agent moves from `working` to `done` or
`blocked`. The client checks the exact pane generation and owns every
host-audio resource. A headless runtime never opens an audio device or starts
a playback command.

## End-to-end path

```text
runtime agent transition
        |
agent_sound.publish -> Delivery responses.pushAgentSound
        |
schema.agent_sound
        |
runtime_messages.handleServerMessage
        |
agent_sound.applyAgentSound
        |
model.agent_snapshot.find (exact key)
        |
SoundPlayback.request -> client.to_background (.sound job)
        |
client.Message.sound_played <- job_runner: sound_playback.play
        |
Client.update -> agent_sound.completeAgentSound
        |
SoundPlayback.complete
```

The runtime message carries a pane ID, pane generation and semantic sound
kind. `agent_sound.applyAgentSound` translates that identity into an `AgentKey`.
`agent_sound.applyAgentSound` schedules playback only when the current client
replica contains the exact key. A delayed message for an earlier process
cannot make noise after the numeric pane ID has been reused.

The operation mutates only `model.sound_playback`. Accepted, stale and
configuration-filtered sounds leave every model version unchanged. The adapter
still calls `Client.presentation.observe` after the turn; it sees no new
revision and asks for no frame.

## Playback ownership and bounds

`SoundPlayback` (`model.sound_playback`) owns the effective `SoundPolicy`, one
active worker token and one optional queued `AgentSound`. `Client`
knows none of its queue transitions. It queues a `.sound` job on
`Client.to_background`; the adapter runs it through its inbox and returns the
completion as `client.Message.sound_played`, which `Client.update`
hands to `agent_sound.completeAgentSound`.

The queue has fixed depth. A request starts immediately when no worker is
active. Further requests fold into the one queued value. `needs_input` wins
over `ready`, since an unanswered prompt should not be hidden by a later
completion sound. Repetition cannot increase memory use or process count.

A validated configuration adoption calls `SoundPlayback.configure`. New requests
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
queue. Failure to start the worker calls `SoundPlayback.schedulingFailed`,
which releases the reserved token, and propagates the scheduling error.

Client teardown cancels the adapter inbox's tasks. A reconnect constructs a
fresh `SoundPlayback`; it neither restores nor replays old audio work. Runtime agent state
continues independently and later exact sound events may start a new queue.

## Validation

- `src/model/config/SoundPolicy.zig` proves per-kind policy filtering.
- `src/model/agents/sound_playback.zig` proves one active token, one coalesced
  successor, priority, configuration replacement and scheduling failure
  recovery.
- `src/client/agents/sound_playback.zig` owns the bounded host adapters; the
  cross build compiles the Linux and Windows paths.
- `src/client/agents/agent_sound.zig` proves exact-identity
  gating, stale suppression and effect-error propagation.
- `src/client/agents/agent_sound.zig` owns protocol translation, worker
  scheduling and the completion entrypoint.
- `src/client_tests/notifications_and_agents.zig` proves wire identity,
  bounded queuing, worker failure recovery, unchanged model and presentation
  versions, and configuration adoption.
- `src/backend/runtime/tests/observation_events_test.zig` proves the exact
  transition policy and the pane generation used by the client gate.
