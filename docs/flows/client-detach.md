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
tab_attachments.detach for every tab
        |
finish captured paste -> report focus-out -> detach_pane messages
        |
mark local attachments hidden and detached
        |
return Control.stop
```

`client_detachments.apply` iterates tabs in their stable client order. Each tab
uses the existing attachment boundary, which finishes a captured bracketed
paste and reports focus-out before it enqueues that tab's `detach_pane`
messages. Pending attachment requests are retired so a late confirmation
cannot restore client ownership.

The operation advances no `ClientModel.Version` and schedules no frame. The
event loop exits after every detach enters the bounded runtime outbox. Client
shutdown then drains no further UI work and destroys only disposable state.

If the outbox rejects any message, the action returns the error instead of
stopping. Earlier detach messages and local attachment changes remain applied;
the client session terminates through the normal error path, while the runtime
keeps all panes valid.

## Proof

- `src/frontend/client/tab_attachments.zig` proves paste, focus and pane detach
  ordering for one tab.
- `src/frontend/client/client_detachments.zig` owns traversal across all tabs.
- `src/frontend/client/client_test.zig` proves stable multi-tab delivery,
  local attachment cleanup, version silence and the final stop control.
