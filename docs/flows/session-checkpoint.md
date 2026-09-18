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
arguments, then the agent's provider, session reference and session title,
plus its pane kind) and layout (client identity, LRU stamp and the exact bytes
of one `update_client_layout` request). The file version is 4, which adds pane
kinds and permits agent panes with no launch arguments. Version 3 introduced
empty automatic tab labels. Versions 1 through 3 remain readable and treat
panes as terminal panes; version 1 files, which predate the pane title, read
with an empty title. Layouts reuse the wire encoding on purpose: restore
replays them through the same validation that live updates get.

Terminal panes are recorded only when their launch inherited the runtime
environment and their arguments fit `LaunchRecord`. Managed agent panes store
Codex as their provider and an optional conversation reference, with no argv.
Their durable transcript remains owned by Codex.

## Commit policy

Persistence is write-behind. A change marks the state dirty; the maintenance
tick starts one write after the change has settled for the debounce window,
and a change that lands during a write keeps the state dirty for the next
tick. A failed write counts a failure and stays dirty, so the next tick retries.
Shutdown stops connections and children, then cancels and joins the actors.
Only after that join does it release any pending checkpoint buffer and write
the current canonical model synchronously. The model is destroyed afterward,
so the last shape survives `telar server stop` even when an older write or
its completion was still pending. Stopping a child's PTY does not remove its
pane from the model; discarded exit events cannot erase the final snapshot.

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
same `workspace.removeTab` the final pane exit uses, and a workspace left
without tabs goes with it (`State.dropped_tabs` counts them). A tab exists for
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
generation as a typed, bounded token; the checkpoint records it next to the
pane's observed process provider. Screen and proxy guesses cannot authorize
resume. Every changed reference marks the checkpoint dirty, including a new
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
the intended reporter.

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

`State.resumed_agents` counts queued resume commands and direct launches.
It does not confirm that the external CLI accepted its session reference.
Actual agent activity still comes from process observations and lifecycle
reports.

The session title rides along with the reference. The checkpoint records a
pane's title only when it is ready and generated, manual or agent-reported
(`Tracker.durableTitle`);
placeholders and a child's own window title are never written, and a ready
title marks the checkpoint dirty like any other semantic change. On restore
the title is handed over only together with a resume command, so a pane that
comes back as a plain shell never wears the old agent's name. The restored
pane has no agent aggregate yet, so `Tracker.restoreTitle` parks the title in
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

## Proof

- `src/backend/persistence/checkpoint.zig` proves the record round trip,
  version 1 compatibility, title validation and rejection of corrupt,
  truncated and foreign files.
- `src/backend/agent/tracker_support.zig` and `src/backend/agent/restored_titles.zig`
  prove that a restored title reaches only the resumed agent's generation,
  skips title generation and is dropped with its pane. Provider and session
  mismatches cannot transfer pending titles or authorize a different resume.
- `src/backend/runtime/application/session_checkpoint.zig` proves the
  debounce, coalescing and retry state machine and the atomic private write.
- `src/backend/workspace/repository_support.zig` and `src/backend/pane/pane_namespace.zig` prove
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

## Managed agent panes

Agent panes restore through `Application.launchPane(kind = .agent)` and the
existing observation worker. `Session` owns a copied conversation reference
before scheduling its worker. Initialization sends `thread/resume` directly
when a saved reference exists, or `thread/start` for an empty pane. Resume
validates the returned identifier, exact working directory and explicit
workspace permissions with user approvals. It rejects an active conversation
and never sends a prompt
or replays an approval. The returned model and effort are validated against
the current provider catalog. Attached clients recover history through the
existing paginated reader when the resumed snapshot arrives.

Pane identity, tab membership, dimensions and durable title survive; the pane
receives a new generation. The existing client layout replica is applied after
both terminal and agent panes have been rebuilt. Duplicate conversations are
claimed once per startup. The same 16-process bound applies to restored agents.
With `resume_agents = false`, agent panes reopen with new conversations.

A failed provider startup or rejected resume leaves a failed agent pane with
its saved reference, available for a later restart. Checkpoints read the
session's owned publication, including pending startup identity, so shutdown
cannot lose a reference whose notification the runtime has not processed yet.
A contended publication defers the write; it never drops that pane. Identity
changes mark the checkpoint dirty; streaming text does not. Transcript bodies,
pending turns, approvals and child processes are not serialized.

`checkpoint_shutdown_test.zig` exercises mixed terminal and agent panes across
consecutive runtime lifetimes with a fake provider, including shutdown before
startup events are processed and disabled resume. Provider tests cover direct
resume, response ordering, rejection and wrong-directory responses. Encoding
tests cover empty panes, legacy records, invalid kinds, providers and references.
