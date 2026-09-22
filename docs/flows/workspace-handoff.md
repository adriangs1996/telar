# Workspace handoff

A handoff replaces one disposable client projection with another. The runtime
owns membership; the client owns bookmarks, retained layout and a visible empty
state while the existing target opens.

```text
operations/input/actions, agent navigation, resync or canonical tab closure
  -> operations/workspaces/workspace_handoffs
     -> selectWorkspace / requestWorkspace / requestPane / followWorkspace
     -> request: target, admission and bounded preflight
        -> AttachedClient.detachTab for each captured tab
        -> correlated open_pane
        -> Model.departWorkspace
        -> workspace_transitions.release
  -> adapter observes the empty projection

pane_opened(initial_open continuation)
  -> operations/panes/AttachedClient.completePaneOpen
  -> workspace_handoffs.arrival / confirm
     -> Model.arriveWorkspace
     -> workspace_transitions.activate
        -> active resources, host input, workspace snapshot, tab snapshot
  -> adapter observes the arrived projection
```

Selection resolves a position/identity through the model's committed workspace
list. Unknown, already active or blocked choices are suppressed. A workspace
request prefers its remembered pane and retains the workspace as fallback.
An explicit pane request preserves that identity and supplied fallback without
consulting bookmarks. Agent navigation owns the local-versus-remote decision.

Ordinary requests require an idle lifecycle. `followWorkspace` bypasses obsolete
pending requests only after canonical state has already left an empty projection;
a live projection cannot use this authority. Resync for a closed workspace
forgets that bookmark before attempting ordinary predecessor handoff, so failure
cannot restore a runtime identity that disappeared.

Preflight checks two available request IDs (open and synchronous repair) before
checking outbox capacity for paste-end, valid focus-out, every attached or
pending-open detach, and the open. It shares `tab_detachment.requiredCapacity`
with tab close. Failure occurs before any provisional effect and requests no
repair because nothing changed.

After admission, stable tab/pane order determines detach order. Paste finishes
and focus-out precedes detach; all detaches precede the new open on the same
socket. A local detach/open failure keeps the original semantic projection,
restores active graphics in order and requests a coalesced tab snapshot. A
failure of that repair never replaces the original request error.

Only a locally accepted open permits `Model.departWorkspace`. Departure captures
the bookmark and bounded retired pane identities and retains reconciled layouts
for active and inactive tabs. It advances workspace/tab/active-tab/pane revisions
once, then releases local resources silently. The presenter can render that
empty model once; waiting for the reply does not create a redraw loop.

Arrival consumes exact correlation. Saved bookmark geometry is accepted only
for the confirmed tab, while the model prefers that tab's exact retained layout.
`Model.arriveWorkspace` requires an empty projection and constructs root/pane
transactionally before committing. The confirmed pane remains the intended
focus. Canonical tab reconciliation restores the tree only if its pane set
matches; otherwise deterministic runtime order wins. Each successful tab
reconciliation consumes only that tab's retained-layout entry.

Activation validates root identity, attachment and revision deltas, then
synchronizes resources, resumes input, and requests workspace then tab snapshots.
Post-commit delivery errors preserve the arrived model.

A remembered-pane `pane_not_found` failure reaches `workspace_handoffs.recover`.
It forgets the bookmark and retries once against the workspace. The retry has
no fallback, so another failure is fatal rather than an unbounded loop. Other
codes or missing fallback also propagate `RuntimeRequestFailed`.

Departure and preflight use bounded stores and add no queue. Arrival makes the
normal pane buffer/bootstrap allocations before committing. Runtime panes
survive client failure and reconnect.

Source: `src/client/operations/workspaces/workspace_handoffs.zig`,
`workspace_transitions.zig`, `src/client/AttachedClient.zig`.
Tests: `src/frontend/client/tests/synchronization.zig`,
`workspace_lifecycle.zig`, `notifications_and_agents.zig`, and
`src/client/model/tests/workspaces.zig` cover preflight, partial failure,
bookmarks/layout round trips, empty-state presentation, arrival and bounded retry.
