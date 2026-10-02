# Session checkpoint

The runtime persists the restorable shape of a session and rebuilds it when
it starts again. Workspaces, tabs, pane launch commands and client layout
replicas come back; processes do not. A restored terminal pane is a fresh launch of the
same command in the pane's last working directory, and the invariant that
runtime death loses live PTYs still holds.

## End-to-end path

```text
command handler / pane launch / pane collection
        |
session_checkpoint.noteChange -> CheckpointWriter.noteChange (dirty, timestamp)
        |
agent maintenance tick -> agent_maintenance.tick -> session_checkpoint.start
        |
CheckpointWriter.due?  (dirty, settled ≥ 500 ms, no write in flight)
        |
session_checkpoint.encode -> persistence Encoder (owned 4 MiB buffer)
        |
CheckpointWriter.startWrite -> model.select.concurrent(.checkpoint_written, writeFile)   -- worker thread
        |
<path>.tmp (0600) -> fsync -> rename over <path>
        |
Event.checkpoint_written -> session_checkpoint.finish -> CheckpointWriter.completeWrite (retry on failure)

Runtime.start: resources.init -> model.init -> session_checkpoint.restore -> scheduleInitialEvents
        |
read file -> validate every record -> apply
        |
model.workspaces.restore / restoreTab   (original ids, counters advance)
model.panes.reserveRestoredKey + pane_launch.launch (original pane id)
model.client_layouts.replace(decoded update_client_layout)   (validated)
```

## Records

`src/backend/persistence` owns the durable record types (`WorkspaceRecord`,
`TabRecord`, `PaneRecord`, `LayoutRecord`), separate from the
live aggregates and from wire projections (`docs/invariants.md`, Ownership). A checkpoint is a
header (`TELARCKP`, version, id counters) followed by a stream of tagged
records: workspace (id, path, explicit name, first tab), tab (extra tabs in
display order), pane (id, location, cwd, size, NUL-separated launch
arguments, then the agent's provider, session reference and session title) and
layout (client identity, LRU stamp and the exact bytes of one
`update_client_layout` request). The file version is 9: version 6 added
worktree records, version 7 the machine that dispatched each worktree,
which older files read as none, version 8 whether a pane's agent ran its
session in the pane, which older files read as not, and version 9 a 32-bit
length for a pane's launch arguments, which may reach 128 KiB. Version 4 ended each
pane record with a kind byte for the removed agent panes; the reader skips
version 4 agent panes and restores the rest. Its layout records also encode a
surface byte per pane leaf, which the current wire rejects, so restore drops
them and clients fall back to their default layout. Version 3 introduced empty
automatic tab labels. Version 1 files, which predate the pane title, read with
an empty title. Layouts reuse the wire encoding on purpose: restore
replays them through the same validation that live updates get.

Terminal panes are recorded only when their launch inherited the runtime
environment. `LaunchRecord` keeps any command a launch accepts (64 arguments,
128 KiB) on the heap, sized to it, so a pane started with a long prompt comes
back.

## Commit policy

Persistence is write-behind. A change marks the state dirty; the maintenance
tick starts one write after the change has settled for the debounce window,
and a change that lands during a write keeps the state dirty for the next
tick. A failed write counts a failure and stays dirty, so the next tick retries.
Shutdown stops connections and children, then cancels and joins the actors.
Only after that join does it release any pending checkpoint buffer and write
the current canonical model synchronously. The model is destroyed afterward,
so the last shape survives `telar server stop` even when an older write or
its completion was still pending. The proxy stops after that write, so a
proxy tunnel that does not return, which the runtime leaves behind after
`proxy.stop_timeout_ms`, can neither delay the checkpoint nor lose it. Stopping a child's PTY does not remove its
pane from the model; discarded exit events cannot erase the final snapshot.

A session larger than `snapshot_bytes` (4 MiB, the largest file restore reads,
`CheckpointWriter.snapshot_bytes`)
writes the records that fit and drops the rest from the first one that does
not. Records only point back to earlier ones, so the prefix restores. The
runtime reports `session_checkpoint.snapshot_bytes` through
[Limit reached](limit-reached.md) and goes on; it used to stop and kill every
pane. `session_checkpoint.start` never fails, so the rest of the maintenance
tick always runs: a checkpoint it cannot allocate or encode is logged,
counted in `failures` and tried again after the next change.

The interactive path allocates nothing for this: `noteChange` stores a flag
and a timestamp. Encoding runs on the observation-budget tick into a buffer
allocated for that write and freed when the worker completes.

## Restore

Restore runs once, before the listener accepts clients. The whole file is
validated first, including the bounded pane count; a file that fails
validation is renamed to `<path>.corrupt` and the runtime starts empty.
Workspaces and tabs are created first. Pane records are sorted by identity
in fixed storage before launching: runtime slots are reusable, so their
serialization order need not match their increasing identities. Layouts are
applied after panes have been restored and empty tabs retired.
Records that cannot be applied individually (a
tab whose workspace is missing, a pane whose launch fails) are skipped, and
the id counters still advance past every recorded identity so reconnecting
clients never see an id reused for a different pane.

If runtime startup fails after restoring children, rollback stops those
children before joining their actors, then releases panes and workspaces.
It leaves the source checkpoint untouched for a later startup attempt.

After the last record, every tab left without a pane is retired through the
same `model.workspaces.removeTab` the final pane exit uses, and a workspace left
without tabs goes with it (`CheckpointWriter.dropped_tabs` counts them). A tab exists for
clients only together with a running pane: the tab snapshot query answers
`tab_not_found` for an empty one, and a client that selects such a tab treats
that reply as fatal. `src/backend/runtime/instance.zig` proves the sweep with
a pane whose working directory disappeared between runs.

## Fresh start

`telar --fresh` and `telar server --fresh` start a runtime without the
previous session. Before restore, `server.setSessionAside` renames
`session.ckpt` to `session.ckpt.previous`; the runtime then starts empty and
persists to the normal path again, so the replaced session survives exactly
one fresh start and comes back with a rename. The client refuses `--fresh`
when a runtime is already listening (`RuntimeAlreadyRunning`) instead of
attaching to the old session, and rejects it together with `--remote`.
`--fresh` is not a repair: a checkpoint the runtime cannot apply is
quarantined as `.corrupt` on its own.

## Agent resume

An agent reports its own session identifier with `telar agent report-session`
(`report_agent_session` on the wire). The tracker stores it on the exact pane
generation as a typed, bounded token, together with the agent it belongs to:
the agent whose hook reported it, or the pane's agent for a reference the
user reports. The checkpoint records it only while that agent's process runs
in the pane, so a session of one agent is never resumed with another agent in
another agent's pane. Screen guesses cannot authorize resume. Every changed reference marks the checkpoint dirty, including a new
session reported by an already-running agent. Process detection that makes
an earlier reference resumable, and process exit that retires it, also mark
the checkpoint dirty.

On restore, `ResumeSession` validates the built-in provider allowlist and UUID
shape. When `runtime.session.resume_agents` is true, the runtime types the
provider's resume line (`claude --resume <id>`, `codex resume <id>`,
`pi --session <id>`) into the relaunched shell through the normal pane input
queue. If the pane originally launched that agent executable directly, the
runtime instead rebuilds its fixed resume argv. It keeps the original launch
record for later checkpoints, so disabling resume on a subsequent restart
does not replay arguments generated by an earlier restore. Repeated references
for the same provider are resumed only once during a startup pass. Configured
providers carry no resume prefix, and malformed references cannot produce a
resume command. Claude Code hooks receive `session_id` in their input and are
the intended reporter. A pane record also keeps whether the agent ran its
session in the pane's own process (`agent_in_pane`, checkpoint version 8):
a Codex started with `--no-daemon` resumes with `codex resume --no-daemon
<id>`, so the resumed session and its hooks stay in the pane rather than in
the shared `codex app-server` daemon (see
[agent hooks](agent-hooks.md#pane-identity)); any other Codex resumes
without the flag, which older versions refuse. Earlier checkpoints read as
not in the pane.

The provider, reference and optional title remain in the bounded
`RestoredAgents` store until the resumed process is observed. These pending
values are checkpoint-worthy without projecting a live agent. A second
restart before the first hook therefore retains the intended resume. A new
reference supersedes pending metadata, a conflicting provider discards it,
and pane destruction removes it with that exact generation. Shell observations
during startup preserve a pending resume, including shell configuration that
briefly launches another process. A return to the shell after observing the
agent retires that live agent normally. If the resume command fails before
the agent can be observed, the pending intention remains available for the
next restart; it is never reported as a running agent.

`CheckpointWriter.resumed_agents` counts queued resume commands and direct launches.
It does not confirm that the external CLI accepted its session reference.
Actual agent activity still comes from process observations and lifecycle
reports.

The session title rides along with the reference. The checkpoint records a
pane's title only when it is ready and generated, manual or agent-reported
(`agent_status.durableTitle`);
placeholders and a child's own window title are never written, and a ready
title marks the checkpoint dirty like any other semantic change. On restore
the title is handed over only together with a resume command, so a pane that
comes back as a plain shell never wears the old agent's name. The restored
pane has no agent aggregate yet, so `agent_status.restoreTitle` parks the title in
`RestoredAgents`, keyed by the exact pane generation; the first aggregate
with matching process evidence receives the ready title. An early report
does not transfer the saved title to a different provider or session. The
ready title also stops redundant description work for the resumed session. The
pane's new history session receives the same title through
`HistoryService.setSessionTitle`, so the history palette lists the resumed
session under its old name. Closing the pane before the agent appears drops
the parked title.

## Configuration

`config.runtime.session = { persist = true, path = "...", resume_agents = true }`. The default
path is `session.ckpt` next to the history database. `persist = false` keeps
the session volatile.

## Validation

- `src/backend/persistence/checkpoint.zig` proves the record round trip,
  version 1 compatibility, title validation and rejection of corrupt,
  truncated and foreign files.
- `src/backend/agent/tracker_tests.zig` and `src/backend/agent/restored_titles.zig`
  prove that a restored title reaches only the resumed agent's generation,
  skips title generation and is dropped with its pane. Provider and session
  mismatches cannot transfer pending titles or authorize a different resume.
- `src/backend/runtime/tests/agent_status_test.zig` proves that a session
  another agent reported is never resumed with the pane's agent.
- `src/cli/integration/hook_identity.test.mjs` restarts a real runtime with
  two Codex sessions in panes of one directory and checks that each resumes
  in its own pane with `codex resume --no-daemon <id>`, and that a Codex that
  ran without the flag resumes without it.
- `src/backend/persistence/checkpoint.zig` proves that `agent_in_pane` round
  trips and that a version 7 pane record reads as not in the pane.
- `src/backend/runtime/session_checkpoint.zig` proves the
  debounce, coalescing and retry state machine, the atomic private write and
  the resume lines and fixed argv of each built-in agent.
- `src/backend/workspace/Workspaces.zig` and `src/backend/pane/pane_namespace.zig` prove
  identity-preserving restore and counter advancement.
- `src/backend/runtime/instance.zig` proves a restart round trip through a
  real runtime: workspaces, tabs, panes, their identities and the resumed
  agent's session title survive `deinit` followed by `init` on the same
  checkpoint. It also covers a reused slot that serializes newer pane IDs
  ahead of still-live older IDs, repeated restarts before hooks arrive,
  duplicate resume references, direct executable argv and disabling resume
  on a subsequent restart. Process observations persist references that
  arrived before provider detection and retire them when the agent exits.
- `src/backend/runtime/tests/checkpoint_shutdown_test.zig` starts a real
  checkpoint write, adds a tab and renames a workspace before its completion
  is handled, then proves shutdown releases the borrowed buffer and restores
  the latest shape on restart. An injected startup failure also proves that
  restored children are joined and the original checkpoint remains intact.
