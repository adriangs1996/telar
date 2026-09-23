# Pane split

A split is a runtime pane launch with a client-owned layout intention. The
runtime decides whether the pane exists; the client decides where it is shown.
[pane_split.zig](../../src/client/panes/pane_split.zig) owns
`requestPaneSplit`, private `confirmPaneSplit` and private `recoverPaneSplit`.

## Request

Start at the dispatch described in [architecture](../architecture.md#dispatch). In the GUI,
`GuiAdapter.update` dispatches `.input_ready` to `GuiAdapter.inputReady`, which
calls `GuiAdapter.drainInput`.
`dispatchKey` (or the text branch) reaches `routeKey`, which calls
`router.routeEvent(event, context)`. The router returns `.action` with
`.split_pane = .horizontal`. `GuiAdapter.applyInputDecision` executes that request
through `executeAction` → `actions.executeAction`.
Its `.split_pane` case directly calls
`pane_split.requestPaneSplit`. The default `<prefix> %` maps to `.horizontal`: the new
pane is to the right of the original.

```text
actions.executeAction(.split_pane)
  → pane_split.requestPaneSplit
      → model.planPaneSplit
      → enqueue provisional pane_resize
      → sendPaneSplitRequest: retain correlation and enqueue create_pane
```

Planning retains the exact tab, target pane, axis and request-time workbench.
It computes the provisional size, original restoration size and new pane size
without changing the layout revision. A pending pane operation suppresses a
second request. Local delivery or request-registration failure attempts to
restore the original size and propagates failure.

Editor-driven splits call the same operation with an explicit target pane and
command arguments; they do not substitute the current keyboard focus.

## Routed API command

A routed `.pane_split` command enters `runtime_messages.handleServerMessage` as
`.client_command`. Private `completeClientCommand` owns the response, and
`executeClientCommand` validates request status, parses the axis, resolves and
focuses the explicit target, then calls `requestPaneSplit` directly.

The response preserves the original command's request ID, client route and
action. `.admitted` means pane creation was requested; it does not commit the
layout. Only the later `pane_opened` does that. Synchronous validation or
operation failures return `.failed` with the error name. Local commands such
as focusing an existing pane return `.applied`.

The command dispatcher and its pane, navigation, presentation, agent and layout
helpers are private methods on `Client`. They expose no separate
controller modules or callback table.

## Completion

The runtime dispatches `.create_pane` from `client_request.receive` directly to
`pane_split.split`. It commits creation before attachment and
answers with `pane_opened` or `request_failed`.

```text
runtime_io.receiveRuntime
  → runtime_messages.handleServerMessage
      → pane_attachment.completePaneOpen: consume request identity once
          → pane_split.confirmPaneSplit
              → model.commitPaneSplit
              → active geometry / inactive detach / stale cleanup
```

`confirmPaneSplit` rejects a different tab, the original pane identity or
`created = false` before changing the model. It applies the freshly computed
commit immediately; there is no separate effect API accepting retained or
caller-constructed commits.

- Active tab: add and focus the pane, mark it attached, then offer attached
  geometry and synchronize active resources. An effect failure preserves the
  committed runtime creation.
- Inactive tab: record membership without a visible revision, send detach,
  then hide graphics. Switching back uses canonical snapshot and attachment.
- Retired tab: leave the pane unrepresented, detach its runtime attachment and
  coalesce a workspace snapshot request if still observing that workspace.
  Reject an identity already represented in the current model before detaching.

No explicit draw is issued here. Presentation observes the committed model.
Pane geometry and active resource synchronization are
`pane_resize.resizeAttachedPanes` and `pane_focus.synchronizeActivePane`,
called immediately after committing the layout.

## Failure and races

`request_failure.failRuntimeRequest` consumes a failed request. Its concrete switch
calls `pane_split.recoverPaneSplit` directly before publishing a failure notice.
Recovery resolves the retained target against current state: resize an attached
active target, leave an inactive target alone, and suppress obsolete failure
notifications for a retired target or tab.

Pane exit and snapshot reconciliation preserve pending split correlation. A
late success introduces a new runtime identity that must be adopted or detached.
If only the original target disappeared, the surviving tab adopts the new pane.
If its tab disappeared, the stale cleanup above applies.

The operation adds no queue. It uses the existing bounded request tracker and
the coalescing `model.to_runtime` outbox. Request-time geometry remains attached to the continuation
when the host is resized during launch.

## Behavioral checks

- [`gui/tests/navigation.zig`](../../src/gui/tests/navigation.zig): the real
  `acceptInput`/`update` path creates the request; a correlated server event
  enters `update` and produces the horizontal layout.
- [`frontend/client/tests/pane_splits.zig`](../../src/frontend/client/tests/pane_splits.zig):
  pending-request gating, local restoration, invalid replies, committed state
  after effect failure, late identity protection and recovery delivery failure.
- [`frontend/client/tests/pane_lifecycle.zig`](../../src/frontend/client/tests/pane_lifecycle.zig):
  active/inactive/retired tabs, vanished targets, presentation observation and
  stale failure suppression.
- [`frontend/client/tests/synchronization.zig`](../../src/frontend/client/tests/synchronization.zig):
  correlation is consumed once; unrelated replies are rejected; cwd inheritance.
- Model, request tracker and backend create-pane tests retain their ownership,
  transaction and lifecycle coverage.

Tests specific to injected callback ordering or fabricated detached commits
were removed with those APIs. Behavior that remains reachable is tested through
the concrete client and transport.
