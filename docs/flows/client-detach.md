# Client detach

The detach action ends only the current client. Runtime panes, PTYs and their
terminal state remain alive for a later attachment.

## Flow

```text
semantic detach action
        |
client_actions.apply
        |
client_detachments.apply
        |
DetachClientHandler
        |
RetireTabAttachmentsHandler for every tab identity
        |
finish captured paste -> report focus-out -> detach_pane messages
        |
mark local attachments hidden and detached
        |
return Control.stop
```

`DetachClientHandler` captures every current `TabLocation` in stable client
order before the first effect, then delivers each identity through one port.
`client_detachments.apply` supplies that port by composing
`RetireTabAttachmentsHandler`, which finishes a captured bracketed paste and
reports focus-out before it enqueues that tab's `detach_pane` messages. Pending
attachment requests are retired so a late confirmation cannot restore client
ownership. `ClientModel` validates and commits the fixed detachment plan only
after every per-tab effect succeeds.

The operation advances no `ClientModel.Version` and schedules no frame. The
event loop exits after every detach enters the bounded runtime outbox. Client
shutdown then drains no further UI work and destroys only disposable state.

If the outbox rejects any message, the action returns the error instead of
stopping. Earlier paste, focus, detach, continuation or graphics effects remain
applied, while attachment flags for that tab remain uncommitted. The client
session terminates through the normal error path, while the runtime keeps all
panes valid.

## Proof

- `src/frontend/client/application/tab_attachment_retirement.zig` proves
  paste, focus, pane and final model-commit ordering for one tab.
- `src/frontend/client/application/client_detachment.zig` proves stable
  whole-client planning, empty state and partial failure behavior.
- `src/frontend/client/tab_attachments.zig` binds the concrete client effects.
- `src/frontend/client/client_detachments.zig` binds the per-tab retirement
  port without owning traversal policy.
- `src/frontend/client/client_test.zig` proves stable multi-tab delivery,
  local attachment cleanup, version silence and the final stop control.
