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
request_failures.apply
        |
consume request ID -> typed Continuation
        |
HandleRequestFailureHandler
        |
recover, ignore, publish a notification, or report fatal
        |
Client.observeModel -> Presenter
```

`request_failures.apply` is the protocol adapter. It removes the continuation
from the fixed request tracker exactly once. An unknown request ID is a
correlation error. After that boundary, `HandleRequestFailureHandler` receives
only the typed continuation, failure code and borrowed message. It does not
know `Client`, IPC request IDs or presentation.

The handler returns one of four semantic outcomes:

- `ignored`: canonical state already retired the work, or recovery proved the
  target stale.
- `recovered`: the failure was repaired without a user-visible notice.
- `notified`: any required recovery completed and a failure notice was
  published.
- `fatal`: the rejected operation cannot leave this client with a coherent
  projection. The adapter maps this to `RuntimeRequestFailed`.

## Recovery policy

| Continuation | Policy |
| --- | --- |
| `ignored` | Do nothing. |
| `workspace_snapshot`, `tab_snapshot` | Report fatal after consuming the continuation. |
| `initial_open` | Retry once against the fallback workspace only when a remembered pane vanished; otherwise report fatal. |
| `split` | Restore the request-time target size. Suppress the notice when the target is stale. |
| `attach_pane` | On `pane_not_found`, request canonical tab reconciliation before publishing the notice. Other failures do not retry. |
| `close_tab` | Request canonical tab reconciliation before publishing the notice. |
| Other request continuations | Publish a targeted failure notice. |

Recovery runs before notification publication. A recovery error stops the
sequence, while a notification error cannot undo completed recovery. The
continuation has already been consumed in both cases, so a duplicate terminal
response cannot repeat either effect.

The application handler maps each request kind to a stable title and semantic
notification target. `notifications.Center` copies the borrowed failure text
into its fixed `schema.max_notification_message_bytes` buffer. Publication
advances only `ClientModel.Version.notifications`; the client loop passes that
version to `Presenter`, which decides whether a paced frame is needed. No
failure use case requests a draw.

## Bounds and lifetime

This flow allocates no queue or timer. It reuses the request tracker bounded by
`schema.max_panes_per_tab + 8`, the existing recovery ports and the bounded
notification center. Wire validation caps the runtime message at
`schema.max_error_message_bytes`; notification storage keeps a UTF-8 prefix at
its smaller display bound.

Pending continuations and notices are disposable. Client death drops them, and
the runtime keeps the authoritative workspace, tab and pane state needed by a
new client to rebuild its projection.

## Proof

- `src/frontend/client/application/request_failure.zig` proves classification,
  recovery ordering, stale suppression, notification mapping and effect
  failure behavior.
- `src/frontend/client/request_failures.zig` owns correlation, concrete
  recovery adapters and fatal error translation.
- `src/frontend/client/client_test.zig` proves wire correlation, continuation
  consumption, recovery paths, targeted notices and fatal snapshot rejection.
- `src/core/schema/root.zig` and `src/core/schema/codec.zig` prove the bounded
  wire contract.
