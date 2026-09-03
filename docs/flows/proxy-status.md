# Proxy status

The runtime owns whether its TLS interception service exists, whether its host
policy contains a wildcard, and whether Telar's short-lived CA is installed in
system trust. Each disposable client stores that bounded replica so its top
bar can keep both kinds of authority visible. `View` owns neither the replica
nor its transition rules.

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
DeliverProxyStatusHandler
             |
post-commit notification
             |
presentation_lifecycle.observe
             |
Presenter -> View.render(proxy_tls_active, proxy_tls_scope, proxy_system_trusted)
             |
widgets.top_bar
```

The proxy configuration does not change during one runtime process. After a
client requests runtime state, `Delivery.prepare` sends the active bit, scope
enum, and system-trust bit once and records delivery only after the send
commits. The message needs no
runtime revision because a connected runtime cannot publish a second source
state.

## Client transaction

`proxy_status.apply` maps the decoded message into
`ApplyProxyStatusHandler`. The handler asks `ClientModel` to reconcile the
triple. An equal value is a no-op. A changed value advances
`Version.proxy_status` exactly once and returns the previous and current state
plus the local revision before and after the change in a typed commit.

The apply handler delegates only a changed commit.
`DeliverProxyStatusHandler` validates the exact current state, one-step local
revision and transition before mapping it to a notification. Enabling the
proxy produces a warning; disabling it produces an informational notice. A
trust-only change reports installation or removal without claiming that
interception changed.
The adapter supplies only physical publication. A notification failure does
not roll back the committed replica. Neither the dispatcher nor either handler
calls `Presenter`.

## Presentation and recovery

After event dispatch, `presentation_lifecycle.observe` publishes the complete model
version. `Presenter` compares `Version.proxy_status` with the version it last
painted, invalidates chrome and passes `ClientModel.proxyTlsActive()`,
`proxyTlsScope()`, and `proxySystemTrusted()` into the next paced frame. `View`
uses those immutable inputs while composing the top bar and stores no proxy
state. Exact-only interception uses the peach shield; a suffix or global
wildcard uses red. Installed system trust keeps a yellow shield visible when
the proxy is off.

The notification center advances its own model version because notifications
are separate disposable UI state. `presentation_lifecycle.observe` folds that version
with the proxy transition into the next paced frame. The badge still comes
from `ClientModel` through `Presenter`.

A reconnect starts with the inactive client default. The new runtime delivery
cursor sends the process's current value, which reconstructs the badge and
announces activation when needed. The replica and its render mapping allocate
nothing.

## Proof

- `src/backend/runtime/delivery/root.zig` proves one committed status delivery per
  client connection.
- `src/core/schema/root.zig` defines the bounded active, scope, and trust state.
- `src/frontend/client/model/root.zig` proves idempotence and isolated versioning.
- `src/frontend/client/application/agents/proxy_status.zig` proves commit-before-
  delivery ordering, duplicate suppression and retained commits after delivery
  failure.
- `src/frontend/client/application/agents/proxy_status_delivery.zig` proves exact
  transition validation, notification policy and retained commits after
  publication failure.
- `src/frontend/client/tests/notifications_and_agents.zig` proves protocol adaptation, duplicate
  suppression, notifications and presenter-owned badge projection.
- `src/frontend/widgets/top_bar.zig` proves the interception badge retains
  reserved space independently of workspace navigation.
