# Client behavior after direct-operation migration

The removed `application/**` handler tests mostly injected callbacks between a
model commit and its delivery. The current tests enter concrete operations on
`AttachedClient`, dispatch real decoded messages, and inspect owned state,
request correlation and the encoded runtime output. Model and resource tests
remain responsible for their algorithms and ownership rules.

This is a behavior map, not a one-for-one claim about test names or counts.
Final build results belong in the validation report for the complete change.

| Previous handler families | Current evidence | Contract checked |
| --- | --- | --- |
| Pane focus, geometry, attachment, closure, resource release | `src/frontend/client/tests/pane_lifecycle.zig`, `src/client/model/tests/panes.zig` | Focus-out before focus-in; fullscreen attachment recovery; geometry only for attached visible panes; active/inactive/late exits; exact copy/paste/focus ownership; no provisional pane deletion. |
| Pane frames and frame delivery | `src/frontend/client/tests/pane_updates.zig`, `src/client/presentation/headless_tests.zig`, `src/client/panes/tests.zig` | Atomic cell ownership, broken-base recovery, application ACK before host completion, detached frames, allocation-failure cleanup and exact frame retirement. |
| Viewport, copy, mouse and pane input | `src/frontend/client/tests/input_operations.zig`, `src/frontend/client/tests/host_interaction.zig`, `src/client/model/tests/input_and_frames.zig` | Input owners, return-to-bottom before child input, copy/viewport transactions and routing through the real model and outbox. |
| Tab creation, selection, move, rename and attachment retirement | `src/frontend/client/tests/tab_lifecycle.zig`, `src/frontend/client/tests/pane_lifecycle.zig`, `src/client/model/tests/tabs.zig`, `src/gui/tests/widget_interaction.zig` | Canonical-only labels/order/membership; exact correlation; request gates; preserved initial geometry; paste/focus/detach ordering; canonical drag/drop requests. |
| Tab close, preflight, removal and recovery | `src/frontend/client/tests/tab_lifecycle.zig`, `src/frontend/client/tests/synchronization.zig` | Capacity and request-ID checks before provisional detachment; recovery after partial delivery; ignored late responses; inactive removal; predecessor handoff and final exit. |
| Tab/workspace snapshot delivery | `src/frontend/client/tests/synchronization.zig`, `src/client/model/tests/tabs.zig`, `src/client/model/tests/workspaces.zig` | Correlation/type/location rejection; complete canonical validation; retained layouts; exact removed-resource cleanup; canonical no-ops; coalesced repair. |
| Workspace creation, targeting, handoff, arrival and activation | `src/frontend/client/tests/workspace_lifecycle.zig`, `src/frontend/client/tests/synchronization.zig`, `src/client/model/tests/workspaces.zig` | No provisional creation; atomic replacement; request geometry; silent old-resource retirement; bookmarks and saved layouts; departure after accepted open; snapshot ordering; one bounded remembered-pane retry. |
| Agent snapshot, navigation, sound, proxy/metrics observation | `src/frontend/client/tests/notifications_and_agents.zig`, `src/client/model/tests/observations.zig`, `src/client/application/agents/agent_reading.zig` | Canonical revision ownership; bounded alerts; identity validation; navigation; sound completion and scheduling failure; owned observation replicas. |
| Agent thread, history and change review | `src/client/application/agents/agent_thread_tests.zig`, `src/gui/tests/agent_history.zig`, `src/gui/tests/change_review.zig` | Prompt/composer revision ownership; conversation generations; request pressure and retries; retired replies; borrowed history lifetime; exact autosave acknowledgement; unsaved range retention and close/reopen. |
| Notifications, request failures, resync and detach | `src/frontend/client/tests/notifications_and_agents.zig`, `src/frontend/client/tests/synchronization.zig`, `src/frontend/client/tests/pane_lifecycle.zig` | Owned notification text; unknown/consumed correlation; repair before notification; fatal snapshot failure; snapshot coalescence; bookmark retirement; ordered multi-tab detach without destroying runtime panes. |
| Host/configuration resources and graphics/clipboard delivery | `src/frontend/client/tests/host_resources.zig`, `src/frontend/client/tests/graphics_and_clipboard.zig`, `src/client/model/tests/configuration_and_host.zig` | Committed configuration before dependent resources; failure retention; shared-image downgrade before snapshot recovery; invalid clipboard rejection; semantic versus physical revisions. |
| Presentation completion | `src/client/presentation/headless_tests.zig`, `src/frontend/client/tests/presentation.zig`, `src/gui/tests/terminal.zig` | Single-flight tokens; failed/cancelled delivery preserves damage; newer frames progress while output is busy; attachment generation ABA; independent media credit and retained leases; isolated client state. |

## Added integration coverage during the audit

The audit added request-validation, full-outbox and post-commit delivery-failure
cases to `tab_lifecycle.zig` and `workspace_lifecycle.zig`. These assert that a
failed request leaves the original projection intact, whereas a confirmed
runtime creation remains committed if later client resource delivery fails.

`notifications_and_agents.zig` adds the following cases through decoded wire
messages and the real client:

- A failed host sound schedule releases its pending token; a later valid
  request can schedule successfully.
- A canonical agent snapshot retains every status change while publishing at
  most the notification capacity of alerts.
- A failed host alert keeps the canonical agent revision and owned notification;
  replaying the same revision does not repeat the host effect.
- Failed attachment recovery consumes its correlation and suppresses a notice
  when the repair request itself cannot enter the outbox.
- A host notification failure preserves an already queued canonical repair;
  the consumed original failure cannot run that repair again.

`synchronization.zig` adds full-outbox resync failure followed by a successful
retry and coalescence. This checks that failed delivery releases correlation
instead of leaving a phantom pending snapshot.

Host failure injection uses existing sound and notification service ports.
It does not recreate erased callbacks between internal client operations.

## Tests that no longer describe a callable boundary

Several removed tests manufactured a stale delivery commit, changed the model
through a fake callback, then invoked a separate handler with that old value.
Where commit and delivery now happen synchronously inside one concrete
operation, callers cannot supply that intermediate value. Recreating a handler
solely to retain those tests would restore the indirection being removed.

Actual asynchronous stale-state boundaries still need tests: wire request
identities, late attachment replies, saved layouts, model transactions, captured
input, agent conversations and presentation attachment generations. The suites
above exercise those boundaries. Separately callable deliveries, including
viewport and focus delivery shared by compound input transactions, retain their
exact-state validation.
