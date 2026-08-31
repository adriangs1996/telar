# Proxy status

The runtime owns whether its TLS interception service exists. Each disposable
client stores one boolean replica so its top bar can keep interception visible.
`View` owns neither that boolean nor its transition rules.

## End-to-end path

```text
runtime proxy service configuration
             |
runtime Delivery.prepare
             |
schema.proxy_status
             |
server_messages dispatcher
             |
proxy_status adapter
             |
ApplyProxyStatusHandler
             |
ClientModel.reconcileProxyStatus
             |
ProxyStatusCommit + Version.proxy_status
             |
post-commit notification
             |
presentation_lifecycle.observe
             |
Presenter -> View.render(proxy_tls_active)
             |
widgets.top_bar
```

The proxy configuration does not change during one runtime process. After a
client requests runtime state, `Delivery.prepare` sends the current boolean
once and records delivery only after the send commits. The message needs no
runtime revision because a connected runtime cannot publish a second source
state.

## Client transaction

`proxy_status.apply` maps the decoded message into
`ApplyProxyStatusHandler`. The handler asks `ClientModel` to reconcile the
boolean. An equal value is a no-op. A changed value advances
`Version.proxy_status` exactly once and returns the previous and current state
in a typed commit.

The handler announces the transition only after the model commit. Enabling the
proxy produces a warning; disabling it produces an informational notice. A
notification failure does not roll back the committed replica. Neither the
dispatcher nor the handler calls `Presenter`.

## Presentation and recovery

After event dispatch, `presentation_lifecycle.observe` publishes the complete model
version. `Presenter` compares `Version.proxy_status` with the version it last
painted, invalidates chrome and passes `ClientModel.proxyTlsActive()` into the
next paced frame. `View` uses that immutable input while composing the top bar
and stores no proxy state.

The notification center advances its own model version because notifications
are separate disposable UI state. `presentation_lifecycle.observe` folds that version
with the proxy transition into the next paced frame. The badge still comes
from `ClientModel` through `Presenter`.

A reconnect starts with the inactive client default. The new runtime delivery
cursor sends the process's current value, which reconstructs the badge and
announces activation when needed. The replica and its render mapping allocate
nothing.

## Proof

- `src/backend/runtime/delivery.zig` proves one committed status delivery per
  client connection.
- `src/core/schema/root.zig` defines the bounded boolean wire value.
- `src/frontend/client/model.zig` proves idempotence and isolated versioning.
- `src/frontend/client/application/proxy_status.zig` proves commit-before-
  announcement ordering and retained commits after effect failure.
- `src/frontend/client/client_test.zig` proves protocol adaptation, duplicate
  suppression, notifications and presenter-owned badge projection.
- `src/frontend/widgets/top_bar.zig` proves the interception badge retains
  reserved space independently of workspace navigation.
