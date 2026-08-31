# Pane frame

A pane frame is the runtime's bounded screen projection for one client
attachment. The client commits that projection to disposable state, repairs
client-only resources and presents it before acknowledging the frame. The
runtime remains authoritative for terminal history and never publishes the
next dependent patch until the acknowledgement arrives.

## Client boundary

```text
schema.pane_frame
       |
server_messages dispatcher
       |
pane_frames adapter
       |
ApplyPaneFrameHandler
       |
ClientModel.applyPaneFrame
       |
multiplexer.Model.applyFrame + copy-mode reconciliation
       |
PaneFrameOutcome
       |
       +-- detached -> no effects
       +-- resync   -> request_snapshot
       +-- applied  -> graphics, reported-focus sync and telemetry
                              |
                    ClientModel.Version.frame
                              |
                    presentation_lifecycle.observe
                              |
                     host flush -> frame_ack
```

`ClientModel.applyPaneFrame` owns the semantic transaction. It resolves pane
membership, rejects frames for unknown panes, ignores frames made stale by
detach and compares patch bases with the last applied frame. A broken base
returns the pane identity and known frame id without changing the model.

A valid frame applies cells, cursor, mouse mode, input modes and scroll state
through `multiplexer.Model.applyFrame`. It also reconciles active copy state
against retained-history pruning before publishing one frame revision. The
returned commit contains values only: pane and tab identity, frame id,
visibility, snapshot status, applied work and the committed revision.

Every successfully applied frame advances `ClientModel.Version.frame`, even
when it changes no visible cell. The revision represents an acknowledgement
obligation as well as screen content. Failed application, broken bases and
detached frames do not advance it.

## Effects and failure policy

`ApplyPaneFrameHandler` runs recovery or post-commit effects according to the
model outcome. The `pane_frames` adapter maps a broken base to
`request_snapshot`. After a valid commit it synchronizes pane graphics
visibility, delegates terminal focus modes to `PaneFocusReportingHandler` and
records frame telemetry against the committed state. A focused pane that has
just enabled focus events receives one focus-in. Report state advances no
presentation revision.

No use case or protocol adapter requests a draw. If a resource effect fails,
the applied frame and copy-state reconciliation remain committed. Rolling them
back would invent a second client state after the runtime frame was already
accepted; reconnect or canonical reconciliation repairs disposable resources.

## Presentation and acknowledgement

After each event, the client loop publishes the latest model version through
`presentation_lifecycle.observe`. `Presenter` compares that value with the
version it last observed and folds all pending revisions into one paced draw.
Frame application already records pane damage and composition invalidation in the multiplexer,
so the presenter only decides when to paint.

`Presenter.presentDue` composes the active model and flushes the terminal cell
diff. Only after that flush succeeds does it consume each attached pane's
pending frame id and enqueue `frame_ack`. A frame therefore cannot release the
runtime's next dependent patch before the corresponding client state has
reached the host terminal.

## Proof

- `src/frontend/client/model.zig` proves atomic screen and copy-state commit,
  exact revisions, stale detach handling, base recovery and failed-apply
  behavior.
- `src/frontend/client/application/pane_frame.zig` proves effect selection,
  commit-before-effect ordering and failure policy.
- `src/frontend/client/client_test.zig` proves recovery IPC, resource
  synchronization, presenter-owned scheduling and acknowledgement after
  presentation.
- `src/frontend/workspace/multiplexer.zig` proves bounded frame application,
  damage tracking and pending-frame consumption.
- `src/backend/runtime/encoder.zig` and runtime attachment tests prove diff
  publication against acknowledged bases.
