# Session checkpoint

The runtime persists the restorable shape of a session and rebuilds it when
it starts again. Workspaces, tabs, pane launch commands and client layout
replicas come back; processes do not. A restored pane is a fresh launch of the
same command in the pane's last working directory, and the invariant that
runtime death loses live PTYs still holds.

## End-to-end path

```text
command handler / pane launch / pane collection
        |
Application.noteSessionChange -> session.State.noteChange (dirty, timestamp)
        |
agent maintenance tick -> Application.flushSessionCheckpoint
        |
State.due?  (dirty, settled ≥ 500 ms, no write in flight)
        |
SessionCheckpoint.encode -> persistence.checkpoint.Encoder (owned 1 MiB buffer)
        |
select.concurrent(.checkpoint_written, writeFile)   -- worker thread
        |
<path>.tmp (0600) -> fsync -> rename over <path>
        |
Event.checkpoint_written -> State.completeWrite (retry on failure)

runtime start: Resources -> Application -> restoreSession -> listener
        |
read file -> validate every record -> apply
        |
Repository.restoreWorkspace / restoreTab   (original ids, counters advance)
PaneStore.reserveRestoredKey + Application.launchPane (original pane id)
ClientLayoutStore.replace(decoded update_client_layout)   (validated)
```

## Records

`persistence.checkpoint` owns the durable record types, separate from the
live aggregates and from wire projections (ADR 0005). A checkpoint is a
header (`TELARCKP`, version, id counters) followed by a stream of tagged
records: workspace (id, path, explicit name, first tab), tab (extra tabs in
display order), pane (id, location, cwd, size, NUL-separated launch
arguments, then the agent's provider, session reference and session title)
and layout (client identity, LRU stamp and the exact bytes of one
`update_client_layout` request). The file version is 2; version 1 files,
which predate the pane title, still read with an empty title. Layouts reuse the wire encoding on purpose:
restore replays them through the same validation that live updates get.

Only panes whose launch inherited the runtime environment and whose arguments
fit `LaunchRecord` are recorded. Everything else restores as absent.

## Commit policy

Persistence is write-behind. A change marks the state dirty; the maintenance
tick starts one write after the change has settled for the debounce window,
and a change that lands during a write keeps the state dirty for the next
tick. A failed write counts a failure and stays dirty, so the next tick retries.
Shutdown writes synchronously once client connections stop and before panes
are torn down, so the last shape survives `telar server stop`.

The interactive path allocates nothing for this: `noteChange` stores a flag
and a timestamp. Encoding runs on the observation-budget tick into a buffer
allocated for that write and freed when the worker completes.

## Restore

Restore runs once, before the listener accepts clients. The whole file is
validated first; a file that fails validation is renamed to `<path>.corrupt`
and the runtime starts empty. Records that cannot be applied individually (a
tab whose workspace is missing, a pane whose launch fails) are skipped, and
the id counters still advance past every recorded identity so reconnecting
clients never see an id reused for a different pane.

## Agent resume

An agent reports its own session identifier with `telar agent report-session`
(`report_agent_session` on the wire). The tracker stores it on the exact pane
generation as a typed, bounded token; the checkpoint records it next to the
pane's provider. On restore, when `runtime.session.resume_agents` is true and
the reference is shaped like a UUID, the runtime types the official resume
line for a built-in provider (`claude --resume <id>`, `codex resume <id>`,
`pi --session <id>`)
into the relaunched shell through the normal pane input queue. Only the
allowlist can produce a command; custom providers and malformed references
restore as plain shells. Claude Code hooks receive `session_id` in their
input and are the intended reporter.

The session title rides along with the reference. The checkpoint records a
pane's title only when it is ready and generated or manual (`Tracker.durableTitle`);
placeholders and a child's own window title are never written, and a ready
title marks the checkpoint dirty like any other semantic change. On restore
the title is handed over only together with a resume command, so a pane that
comes back as a plain shell never wears the old agent's name. The restored
pane has no agent aggregate yet, so `Tracker.restoreTitle` parks the title in
a bounded store keyed by the exact pane generation; the first aggregate
created for that generation starts with the title ready and final, which
also stops the description job for the resumed session's first prompt. The
pane's new history session receives the same title through
`HistoryService.setSessionTitle`, so the history palette lists the resumed
session under its old name. Closing the pane before the agent appears drops
the parked title.

## Configuration

`config.runtime.session = { persist = true, path = "...", resume_agents = true }`. The default
path is `session.ckpt` next to the history database. `persist = false` keeps
the session volatile.

## Proof

- `src/backend/persistence/checkpoint.zig` proves the record round trip,
  version 1 compatibility, title validation and rejection of corrupt,
  truncated and foreign files.
- `src/backend/agent/tracker.zig` and `src/backend/agent/restored_titles.zig`
  prove that a restored title reaches only the resumed agent's generation,
  skips title generation and is dropped with its pane.
- `src/backend/runtime/application/session_checkpoint.zig` proves the
  debounce, coalescing and retry state machine and the atomic private write.
- `src/backend/workspace/repository.zig` and `src/backend/pane/root.zig` prove
  identity-preserving restore and counter advancement.
- `src/backend/runtime/instance.zig` proves a restart round trip through a
  real runtime: workspaces, tabs, panes, their identities and the resumed
  agent's session title survive `deinit` followed by `init` on the same
  checkpoint.
