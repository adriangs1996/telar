# Request failure

The runtime rejects an accepted client request with `schema.request_failed`.
The response carries the original request ID, a bounded failure code and a
UTF-8 message of at most `schema.max_error_message_bytes`. Runtime state stays
authoritative; the disposable client decides only how to repair its local
conversation and how to expose the rejection.

## Client boundary

```text
schema.request_failed
        |
AttachedClient.failRuntimeRequest
        |
consume request ID -> typed Continuation
        |
recover, ignore, publish a notification, or report fatal/error
        |
presentation_lifecycle.observe -> Presenter
```

`AttachedClient.handleServerMessage` first lets `history_palette.fail` claim a
failed history search. Otherwise `AttachedClient.failRuntimeRequest` takes the
continuation from `model.request_lifecycle.tracker` once and switches directly
on the retained operation. Unknown identities report the bounded runtime message and
return `UnexpectedRequestFailure`. Known requests call their concrete recovery
before publishing a notification; an error reports the runtime message once
and propagates.

The operation returns `ignored`, `recovered` or `notified`. Snapshot failures
and unrecoverable initial opens return `RuntimeRequestFailed` directly. There
is no separate failure handler or callback assembly.

## Recovery policy

| Continuation | Policy |
| --- | --- |
| `ignored` | Do nothing. |
| `workspace_snapshot`, `tab_snapshot` | Report fatal after consuming the continuation. |
| `initial_open` | Retry once against the fallback workspace only when a remembered pane vanished; otherwise report fatal. |
| `split` | Restore geometry for the exact requested target. Suppress the notice when the target is stale. |
| `attach_pane` | On `pane_not_found`, request canonical tab reconciliation before publishing the notice. Other failures do not retry. |
| `close_tab` | Request canonical tab reconciliation before publishing the notice. |
| Other request continuations | Publish a targeted failure notice. |

Recovery runs before notification publication. A recovery error stops the
sequence, while a notification error cannot undo completed recovery. The
continuation has already been consumed in both cases, so a duplicate terminal
response cannot repeat either effect. Both processing errors are reported once
before the original error propagates. Successful ignored, recovered and
notified outcomes do not report an error.

The pure `request_failure.notification` function maps each request kind to a stable title and semantic
notification target. `notifications.Center` copies the borrowed failure text
into its fixed `schema.max_notification_message_bytes` buffer. Publication
advances only `model.notifications_revision`, which `ClientModel.version`
reports as `notifications`. After the event, the TUI's `events.zig` calls
`presentation_lifecycle.observe`, which hands that version to `Presenter`; the
presenter decides whether a paced frame is needed. No
failure path requests a draw.

## Bounds and lifetime

This flow allocates no queue or timer. It reuses the request tracker bounded by
`schema.max_panes_per_tab + 8`, the existing recovery operations and the bounded
notification center. Wire validation caps the runtime message at
`schema.max_error_message_bytes`; notification storage keeps a UTF-8 prefix at
its smaller display bound.

Pending continuations and notices are disposable. Client death drops them, and
the runtime keeps the authoritative workspace, tab and pane state needed by a
new client to rebuild its projection.

## Validation

- `src/model/connection/request_failure.zig` checks notification
  title, target, message and duration mapping.
- `src/client/AttachedClient.zig` owns correlation,
  concrete recovery dispatch and error reporting.
- `src/frontend/client/tests/pane_splits.zig` checks that failed recovery
  consumes correlation without publishing a notification.
- `src/model/connection/RequestLifecycle.zig` proves bounded identity and
  exactly-once correlation entrypoints.
- `src/frontend/client/tests/` proves wire correlation, continuation
  consumption, recovery paths, targeted notices and fatal snapshot rejection.
- `src/core/schema/schema.zig` and `src/core/schema/codec.zig` prove the bounded
  wire contract.
