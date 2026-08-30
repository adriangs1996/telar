# Backend refactoring plan

This document is the finite inventory for the backend refactor. A slice is a
complete externally triggered behavior, not a source file. Internal helpers are
refactored as part of the slice that owns their behavior.

Frontend behavior and frontend-owned state are explicitly out of scope.

## Completion contract

A slice is **ready** only when the repository proves all applicable properties:

- Its external trigger has one explicit backend entrypoint.
- The event loop classifies and delegates; it does not implement the use case.
- A client mutation is split into protocol controller, command handler, domain
  model/repository, typed domain event, and infrastructure ports where those
  roles exist.
- Public dependencies are cohesive contexts or ports with at most three
  parameters per function.
- Runtime-owned state is mutated only through its owning aggregate or
  capability root.
- Queued events and responses own every byte they outlive.
- The interactive, media, and observation budgets remain separated.
- Unit tests cover successful behavior, expected failures, effect ordering,
  rollback or backpressure where applicable, and idempotency where applicable.
- At least one integration or vertical test exercises the public composition
  boundary for behavior that crosses layers.
- `just test`, `just check`, and `just test -Doptimize=ReleaseFast` pass before
  the slice commit.

Status values:

- **Ready**: the completion contract is satisfied and verified.
- **Pending**: the current implementation still mixes responsibilities or lacks
  sufficient proof.
- **In progress**: exactly the slice currently being changed.

## Client-request slices

Every row is anchored to one `schema.ClientMessage` variant, so adding a new
protocol request necessarily extends this inventory.

| ID | Trigger | Current entrypoint | Target owner | Status | Evidence / missing proof |
| --- | --- | --- | --- | --- | --- |
| BCR-01 | `open_pane` | `runtime/controllers/open_pane.zig` | Open-pane controller and launch/attachment command | Ready | Explicit/default/workspace selection, invisible workspace proposal, geometry and launch rollback, typed events, post-commit durability, response mapping, backpressure, root-path naming, and vertical integration tests pass. |
| BCR-02 | `pane_input` | `runtime/controllers/pane_input.zig` | Attachment input controller and pane-input command | Ready | Statically dispatched controller, typed stale outcomes, aggregate-owned bounded queue, agent toggle, close/exit boundaries, effect ordering, scheduler failures, saturation, byte ownership, vertical flow, and repeated transport tests pass without allocations. |
| BCR-03 | `pane_resize` | `runtime/controllers/pane_resize.zig` | Attachment resize controller and geometry command | Ready | Typed policy outcomes, client-bound geometry lease, deferred/immediate/idempotent paths, PTY and scheduler failures, pane and attachment allocation rollback, last/non-last detach semantics, effect ordering, vertical flow, and transport tests pass. |
| BCR-04 | `frame_ack` | `runtime/controllers/frame_ack.zig` | Frame acknowledgement controller and command | Ready | Static controller, aggregate-owned exact-frame mutation, foreign, future, obsolete, and duplicate ACK rejection, recovery preservation, accepted latency telemetry, and Debug, ReleaseFast, build, and transport tests pass. |
| BCR-05 | `request_snapshot` | `runtime/controllers/request_snapshot.zig` | Cell-resynchronization controller and command | Ready | Static controller, aggregate-owned coalescing, advisory client baseline, missing-pane isolation, stale accounting, outstanding-frame replacement, base-zero recovery, and Debug, ReleaseFast, build, and transport tests pass. |
| BCR-06 | `detach_pane` | `runtime/controllers/detach_pane.zig` | Detach controller and attachment command | Ready | Two-phase attachment/workspace departure, stale accounting, geometry release, lifecycle ordering, state-conflict, controller, vertical, and repeated transport tests pass. |
| BCR-07 | `runtime_stop` | `runtime/entrypoints/control.zig` | Runtime control controller | Pending | Small, but shutdown authority and acknowledgement semantics lack focused tests. |
| BCR-08 | `request_tab_snapshot` | `runtime/controllers/tab_snapshot.zig` | Tab snapshot query controller | Ready | Query/source boundary, protocol mapping, absence, short-circuit, unexpected-error, backpressure, and vertical tests pass. |
| BCR-09 | `create_pane` | `runtime/controllers/create_pane.zig` | Create-pane controller and launch command | Ready | Typed generation-safe `PaneLaunched`; handler/controller cover live-tab validation, authority, launch errors, post-commit attachment failure, ordering, protocol mapping, and vertical backpressure. |
| BCR-10 | `close_pane` | `runtime/controllers/close_pane.zig` | Close-pane controller and pane lifecycle command | Ready | `Pane.requestClose` is the sole close transition; handler/controller cover authorization, idempotency, no-success-ack semantics, errors, backpressure, and vertical flow. |
| BCR-11 | `query_history` | `runtime/entrypoints/history.zig` | History query controller and observation service port | Pending | Six-parameter entrypoint and asynchronous reply ownership need separation. |
| BCR-12 | `request_workspace_snapshot` | `runtime/controllers/workspace_snapshot.zig` | Workspace snapshot query controller | Ready | Reader-backed query, protocol mapping, missing identities, worktree, unexpected-error, backpressure, and vertical tests pass. |
| BCR-13 | `create_tab` | `runtime/controllers/create_tab.zig` | `CreateTabHandler` and workspace aggregate | Ready | Commits `e002c34`, `dc5f8ce`; command, controller, rollback, backpressure, and vertical tests exist. |
| BCR-14 | `rename_tab` | `runtime/controllers/tab.zig` | `RenameTabHandler` and workspace aggregate | Ready | Commits `a35fe64`, `dc5f8ce`; owned `TabRenamed`, command/controller tests, and vertical backpressure test exist. |
| BCR-15 | `close_tab` | `runtime/controllers/close_tab.zig` | `CloseTabHandler` and workspace aggregate | Ready | Commit `278a9de`; typed `TabRemoved`, effect-order tests, and vertical backpressure test exist. |
| BCR-16 | `move_tab` | `runtime/controllers/move_tab.zig` | Move-tab controller, command handler, and workspace aggregate | Ready | Typed `TabMoved`; aggregate, handler, controller, edge, error, ordering, and vertical backpressure tests pass. |
| BCR-17 | `request_graphics_snapshot` | `runtime/controllers/request_graphics_snapshot.zig` | Graphics snapshot recovery controller and attachment command | Ready | Aggregate-owned reset, frozen-transfer and quota cleanup, preserved credit/transport policy, coalescing, missing-pane isolation, stale and failure mapping, empty begin/end recovery, vertical delivery, 1552 Debug tests, ReleaseFast, build, and transport gates pass. |
| BCR-18 | `graphics_credit` | `runtime/controllers/graphics_credit.zig` | Graphics flow-control controller and attachment command | Ready | Aggregate-owned exact-bound returns, zero/excess/unrepresentable rejection, saturating arithmetic, missing-pane isolation, stale and failure mapping, blocked-image resumption on the next delivery pump, 1560 Debug tests, ReleaseFast, build, and transport gates pass. |
| BCR-19 | `configure_graphics` | `runtime/entrypoints/attachment.zig` | Client graphics configuration controller | Pending | Session policy and existing attachment updates are coupled. |
| BCR-20 | `request_runtime_state` | `runtime/entrypoints/attachment.zig` | Runtime-state query controller | Pending | Currently a one-line protocol side effect with no focused contract test. |
| BCR-21 | `create_workspace` | `runtime/controllers/create_workspace.zig` | Create-workspace controller and launch command | Ready | Invisible `WorkspaceProposal`, owned `WorkspaceCreated`, command/controller, capacity, authority, geometry, launch rollback, post-commit failure, ordering, ownership, and vertical backpressure tests pass. |
| BCR-22 | `rename_workspace` | `runtime/controllers/rename_workspace.zig` | Rename-workspace controller and command handler | Ready | Owned `WorkspaceRenamed`; aggregate, handler, controller, error, ordering, ownership, and vertical backpressure tests pass. |
| BCR-23 | `set_pane_viewport` | `runtime/controllers/pane_viewport.zig` | Viewport controller and attachment command | Ready | Client isolation, exact clamping, idempotence, snapshot scheduling, missing-pane handling, allocation rollback, shared-screen restoration, Debug, ReleaseFast, build, and transport tests pass. |
| BCR-24 | `copy_selection` | `runtime/controllers/copy_selection.zig` | Selection query controller and bounded query handler | Ready | Absolute and reverse ranges, linewise normalization, column/history bounds, scratch exhaustion, 64 KiB wire limit, stale mapping, pending-clipboard isolation, Debug, ReleaseFast, build, and transport tests pass. |
| BCR-25 | `show_notification` | `runtime/controllers/show_notification.zig` | Notification controller, broadcast handler, and delivery port | Ready | Exact ring-buffer reservation, duplicate request IDs, owned broadcast, UI/control policy, zero recipients, recipient/requester backpressure, delivery ordering, Debug, ReleaseFast, build, and transport tests pass. |

## Runtime-event slices

These rows are anchored to `RuntimeEvent`. Several variants may share one
capability, but each remains independently auditable because it has a distinct
failure and scheduling contract.

| ID | Trigger | Current implementation | Target boundary | Status | Evidence / missing proof |
| --- | --- | --- | --- | --- | --- |
| BRE-01 | `accepted` | `Server.handleAcceptedEvent` | Client admission service | Pending | Socket admission, capacity policy, handshake scheduling, and retry are runtime-root methods. |
| BRE-02 | `handshaken` | `Server.handleHandshakenEvent` | Client admission service | Pending | Authentication completion and receive scheduling remain coupled to `Server`. |
| BRE-03 | `client_message` | `Server.handleClientMessageEvent` / `dispatchClientMessage` | Client request router | Pending | The switch is a composition root but still constructs every use case inline. |
| BRE-04 | `client_sent` | `Server.handleClientSentEvent` | Client delivery capability | Pending | Send completion, detach effects, retry, and connection teardown need an isolated state machine. |
| BRE-05 | `history_response` | `Server.handleHistoryResponseEvent` | History response controller | Pending | Async ownership and control-client close policy need focused proof. |
| BRE-06 | `pane_input_written` | `Server.handlePaneInputWrittenEvent` | Pane input pump | Pending | Queue advancement, metrics, failure, and rescheduling live in runtime root. |
| BRE-07 | `pane_response_written` | `Server.handlePaneResponseWrittenEvent` | PTY response pump | Pending | Response queue progression and pane retirement need isolation. |
| BRE-08 | `pane_output` | `Server.handlePaneOutputEvent` | Interactive pane-output pipeline | Pending | Ingest scheduling, EOF/error handling, and actor accounting need one capability. |
| BRE-09 | `pane_ingested` | `Server.handlePaneIngestedEvent` | Post-ingest coordinator | Pending | Delivery invalidation and observation/media scheduling need explicit budget boundaries. |
| BRE-10 | `pane_observed` | `Server.handlePaneObservedEvent` | Pane observation coordinator | Pending | History, process evidence, agent projection, and follow-up scheduling are mixed. |
| BRE-11 | `pane_media` | `Server.handlePaneMediaEvent` | Media pipeline coordinator | Pending | Media drain, quota enforcement, and client projection need isolated tests. |
| BRE-12 | `pane_exit` | `Server.handlePaneExitEvent` | Pane retirement command | Pending | Pane, workspace, agent, credential, history, and client effects form an unextracted transaction. |
| BRE-13 | `telemetry_tick` | `Server.handleTelemetryTickEvent` | Telemetry sampler | Pending | Sampling and async sink scheduling remain in runtime root. |
| BRE-14 | `telemetry_written` | `Server.handleTelemetryWrittenEvent` | Telemetry sink state | Pending | Write lifecycle lacks an isolated state-machine test. |
| BRE-15 | `proxy_event` | `Server.handleProxyEvent` | Agent observation adapter | Pending | Tracking is modular, but runtime scheduling and error policy remain in `Server`. |
| BRE-16 | `agent_tick` | `Server.handleAgentTickEvent` | Agent maintenance scheduler | Pending | Expiry, projection, description scheduling, and next tick are coupled. |
| BRE-17 | `agent_description` | `Server.handleAgentDescriptionEvent` | Agent description completion handler | Pending | Result ownership and projection need a focused adapter test. |
| BRE-18 | `metrics_tick` | `Server.handleMetricsTickEvent` | Host-metrics sampler | Pending | Polling and delivery invalidation remain runtime-root responsibilities. |
| BRE-19 | `stopped` | `serveInternal` event loop | Runtime shutdown coordinator | Pending | Stop completion relies on the monolithic defer block. |

## Proxy and observation slices

These are network-originated use cases beneath the runtime-facing `Proxy`
capability. HTTP parsing primitives are leaves of these slices, not slices by
themselves.

| ID | External trigger | Current boundary | Target owner | Status | Evidence / missing proof |
| --- | --- | --- | --- | --- | --- |
| BPO-01 | Runtime creates/destroys proxy | `proxy.Proxy.create/destroy/run` | Proxy lifecycle capability | Pending | Root API exists; lifecycle composition and cancellation require audit and focused tests. |
| BPO-02 | Pane launch/revoke | `Proxy.registerPane/revokePane` | Credential capability | Ready | ADR 0004, scoped credential ownership, secure zeroing, environment tests, and revocation tests exist. |
| BPO-03 | TCP proxy connection | `proxy/service.zig` | Bounded connection admission | Pending | Accept, connection quota, worker ownership, and rejection metrics need extraction from `Service`. |
| BPO-04 | HTTP CONNECT authentication | `proxy/service.zig` | Tunnel authentication command | Pending | Parsing, credential lookup, target policy, and response mapping are mixed. |
| BPO-05 | TLS interception | `proxy/tls.zig` / `proxy/service.zig` | TLS tunnel capability | Pending | Protocol selection and certificate failure policy need a narrow orchestration boundary. |
| BPO-06 | HTTP/1 exchange | `proxy/http/root.zig` / `service.zig` | HTTP/1 relay transaction | Pending | Parser leaves are tested; service integration, observation ordering, and cancellation need audit. |
| BPO-07 | HTTP/2 connection and streams | `proxy/h2.zig` / `service.zig` | HTTP/2 relay capability | Pending | Decoder/transcoder coverage is strong, but orchestration and lifecycle remain very large. |
| BPO-08 | Provider request classification | `proxy/provider/*` / middleware | Provider observation adapter | Pending | Classification is modular; exact ownership and unsupported-provider behavior need slice-level proof. |
| BPO-09 | Provider semantic completion | `proxy/sse.zig` / provider adapter | Turn-completion observation | Ready | Bounded streaming decoder, arbitrary chunk-split tests, oversized-event recovery, and tracker completion tests exist. |
| BPO-10 | Observation queue delivery | `proxy/service.zig` / `Proxy.receive` | Bounded observation channel | Pending | Backpressure, revocation filtering, shutdown, and metric semantics need one tested capability. |

## Runtime lifecycle slices

| ID | Trigger | Current implementation | Target owner | Status | Evidence / missing proof |
| --- | --- | --- | --- | --- | --- |
| BRL-01 | `runtime.serve` startup | `runtime/root.zig::serveInternal` | Runtime composition root | Pending | Allocation, history, listener, proxy, actors, telemetry, and model construction are monolithic. |
| BRL-02 | Pane launch | `runtime/pane_launcher.zig` plus runtime adapters | Pane-launch transaction | Ready | ADR 0001 and fault-injection tests cover ownership transfer and rollback. |
| BRL-03 | History worker lifecycle | `serveInternal` | History runtime adapter | Pending | Queue ownership, worker startup, close, await, and degradation are composed inline. |
| BRL-04 | Proxy worker lifecycle | `serveInternal` | Proxy runtime adapter | Pending | Startup, event scheduling, cancellation, and teardown are composed inline. |
| BRL-05 | Runtime shutdown | `serveInternal` defer block | Ordered shutdown coordinator | Pending | Ordering is documented inline but not represented or tested as a capability. |

## Refactoring order

The order follows dependency locality and risk. A slice may expose a smaller
prerequisite slice; if so, the prerequisite is inserted immediately before it
and added to this inventory.

1. Finish tab behavior: BCR-16, BCR-08.
2. Finish workspace behavior: BCR-22, BCR-12, BCR-21.
3. Finish pane lifecycle requests: BCR-10, BCR-09, BCR-01.
4. Extract attachment synchronization requests: BCR-06, BCR-05, BCR-04,
   BCR-23, BCR-24, BCR-17, BCR-18, BCR-19, BCR-20.
5. Extract interactive input and resize: BCR-02, BCR-03.
6. Extract control and history requests: BCR-11, BCR-25, BCR-07.
7. Reduce the client router after all request construction has moved: BRE-03.
8. Extract pane event pipelines: BRE-06 through BRE-12.
9. Extract client admission and delivery: BRE-01, BRE-02, BRE-04, BRE-05.
10. Extract agent, metrics, and telemetry event adapters: BRE-13 through BRE-18.
11. Refactor proxy slices: BPO-01, BPO-03 through BPO-08, BPO-10.
12. Refactor lifecycle composition: BRL-03, BRL-04, BRL-01, BRE-19, BRL-05.
13. Run a final public-boundary, ownership, documentation, and performance
    audit across the backend only.

## Baseline

At the start of this plan, commit `dd356ef` passes `just test`, `just check`,
and `just test -Doptimize=ReleaseFast`. The only untracked path is the
user-owned `.github/` directory, which is outside this refactor.
