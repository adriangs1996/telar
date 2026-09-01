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
arguments) and layout (client identity, LRU stamp and the exact bytes of one
`update_client_layout` request). Layouts reuse the wire encoding on purpose:
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

## Configuration

`config.runtime.session = { persist = true, path = "..." }`. The default
path is `session.ckpt` next to the history database. `persist = false` keeps
the session volatile.

## Proof

- `src/backend/persistence/checkpoint.zig` proves the record round trip and
  rejection of corrupt, truncated and foreign files.
- `src/backend/runtime/application/session_checkpoint.zig` proves the
  debounce, coalescing and retry state machine and the atomic private write.
- `src/backend/workspace/repository.zig` and `src/backend/pane/root.zig` prove
  identity-preserving restore and counter advancement.
- `src/backend/runtime/instance.zig` proves a restart round trip through a
  real runtime: workspaces, tabs, panes and their identities survive
  `deinit` followed by `init` on the same checkpoint.
