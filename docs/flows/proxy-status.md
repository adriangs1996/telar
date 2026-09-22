# Proxy status

The runtime owns whether its TLS interception service exists, whether its host
policy contains a wildcard, and whether Telar's short-lived CA is installed in
system trust. Each disposable client stores that bounded replica so its top
bar can keep both kinds of authority visible. `View` owns neither the replica
nor its transition rules.

## End-to-end path

```text
runtime proxy configuration → runtime delivery → proxy_status
  → AttachedClient.handleServerMessage
  → proxy_status.apply
      model.reconcileProxyStatus
      notification for a changed transition
  → presentation observation → top-bar projection
```

The proxy configuration does not change during one runtime process. After a
client requests runtime state, `Delivery.prepare` sends the active bit, scope
enum, and system-trust bit once and records delivery only after the send
commits. The message needs no
runtime revision because a connected runtime cannot publish a second source
state.

## Client transaction

`proxy_status.apply` asks the model to reconcile the decoded triple. Equal
values are no-ops. A changed value advances the proxy revision and returns the
previous and current state. The same function selects the notification and
calls `notifications.publishNow` immediately.

Enabling interception produces a warning; disabling it produces an informational
notice. Trust-only changes describe trust installation or removal. A publication
failure preserves the committed replica. No intermediate delivery object or
host callback decides the transition; the event loop observes its revisions.

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

## Validation

Model observation tests cover idempotence and isolated revisions. Runtime
delivery tests cover one committed status delivery per connection. The concrete
client suite in `src/frontend/client/tests/notifications_and_agents.zig` covers
wire adaptation, duplicate suppression, notification policy and the badge's
presentation. Top-bar tests cover independent reserved badge space.
