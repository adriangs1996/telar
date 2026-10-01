# Machine activity

The window's activity sidebar presents the agents and tracked commands of all
its machines, independently of the machine whose terminal it shows. Each
runtime remains the authority over its own work. A card always names its
machine, and navigation carries that machine and an exact pane generation.

Worktree dispatch records an optional coordinator reference. It reuses the
random 128-bit pane session identity already in agent snapshots, plus the
pane id and generation. The source runtime verifies the dispatching process's
descent before the CLI derives that reference. The destination stores it as
attribution only and never connects back or uses it as execution authority.

The client matches this reference across its machine replicas. A delegated
task follows its matching coordinator even when they run on different machines.
An unmatched task remains visible. Old local registrations still use their
local created_by attribution; a foreign pane number is never interpreted as
a local parent.

Snapshots and workspace-list revisions invalidate a bounded presentation
order. A sorted identity index resolves explicit parent references in logarithmic
time, and iterative linear walks break cycles and emit the tree. Painting borrows the canonical replicas rather than copying agent
truth or polling remote commands. Lost connections retain their last cards
with an explicit disconnected indication; they do not appear to have become
idle or finished. Connecting another machine does not attach its terminals.

The projects and terminal area retain the active machine's context. Opening
an activity switches to the owning machine before resolving its pane. Stable
session identity and pane generation prevent coincident pane ids or stale
cards from navigating to another process.

Primary clicks open the owning machine and its exact agent. Secondary clicks
open that machine's existing agent inspector. On the already shown machine,
the inspector keeps the current tab. Both actions revalidate the session
identity after any frame or workspace handoff in flight; vanished sessions
and reused machine slots cancel the pending action.

Commands here are the commands the runtime tracks in worktrees. An agent and
its worktree command share one task card. A command without an agent gets its
own card, including its exit outcome; clicking it opens its workspace when
that workspace still exists. Arbitrary untracked shell processes and future
machine-execution jobs require their own metadata feed and are not inferred
from terminal output.

The optional `--coordinator HEX_SESSION:PANE:GENERATION` argument belongs to
forwarded `worktree create` calls. Normal callers inside an agent pane do not
supply it: the CLI derives it after `verify_pane_descent`. Worktree-list JSON
exposes `coordinator` as a nullable object with `session_id`, `pane_id` and
`pane_generation`. Agent-list and agent-get JSON expose the matching hex
`session_id`, independent of the provider's conversation reference. Existing registrations without an exact reference remain
unparented across machines; a machine label cannot identify a coordinator.

Checkpoint version 10 persists this attribution and reads older checkpoints
without it. Session identities change when panes are restored after a runtime
restart, so references to a former session become unmatched rather than
binding to a reused pane number. The combined fleet IPC uses schema 85; the client,
CLI and every connected runtime must run the same build.

Validate the real CLI/runtime path with `python3 tools/machine_activity_smoke.py`
after building. It creates a local runtime, repository and simulated agent in
private temporary directories, verifies process descent and automatic parent
capture, accepts a forwarded reference without treating it as local authority,
and checks restoration after a runtime restart. It uses no fleet connection.
