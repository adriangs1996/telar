# Claude turn completion

A Claude model exchange starts when an intercepted `POST /v1/messages` request
reaches the proxy. Telar keeps the agent `working` until the provider protocol
explicitly reports `end_turn`. Finishing the HTTP response is insufficient
because Claude may execute a local tool and start another model exchange.

## Flow

```text
Claude POST /v1/messages
        |
ProxyTLS HTTP/1.1 or HTTP/2 relay
        |
request_started -> Agent Tracker -> working
        |
identity-encoded text/event-stream payload
        |
sse.Decoder -> provider.claude.completesTurn
        |
middleware.provider_turn_completed
        |
observation_queue.Channel -> Proxy.receive
        |
RuntimeEvent.proxy_event
        |
observation_adapter.Adapter.handle
        |
Agent Tracker -> ProxyState
        |
no other model exchange remains
        |
ready projection -> runtime client snapshot
```

`service.HttpResponseObserver.observe` handles HTTP/1.1 body fragments.
`service.H2EventObserver.emit` handles HTTP/2 DATA events. Both feed borrowed
payload bytes to `provider.ResponseObserver` only after the response has a
successful status, an unambiguous `text/event-stream` content type, and no
non-identity content encoding. Forwarding never waits for or depends on this
inspection.

The provider interpreter accepts one non-truncated `message_delta` event only
when its JSON `type` is also `message_delta` and `delta.stop_reason` is
`end_turn`. It rejects malformed JSON, contradictory event types, and
continuation reasons such as `tool_use`.

`TunnelContext.publishStatus` copies the resulting observation into the
bounded proxy queue. `Proxy.receive` removes the credential and exposes the
pane generation. The runtime receives it as `RuntimeEvent.proxy_event` and
delegates to `observation_adapter.Adapter.handle`, which validates the live
pane generation before calling `Agent Tracker.observeProxy`.

`ProxyState` closes only the matching protocol, connection, and stream. It
projects `ready` when no model exchange remains. A later
`response_finished` for the same exchange is ignored and cannot regress the
agent to `working`.

## Recovery and diagnosis

Observation queue saturation may lose lifecycle evidence but cannot delay or
alter proxy traffic. Screen evidence can later recover readiness when the
emulated terminal confirms Claude's input prompt.

The `proxy_claude_*` telemetry counters locate a missing transition without
recording headers or payloads. Their interpretation is documented in
[`proxy-tls.md`](../proxy-tls.md#agent-state).

## Proof

- `HTTP1 Claude SSE publishes provider turn completion after forwarding`
  covers request classification, HTTP framing, byte forwarding, SSE parsing,
  provider interpretation, publication, and queue delivery.
- `HTTP2 observer exposes DATA payload across every two-chunk split` proves
  payload delivery before transport completion for every split of a final
  DATA frame.
- `HTTP2 final DATA publishes Claude completion before transport completion`
  covers provider interpretation, exact stream identity, publication, and
  stream cleanup.
- `Claude provider completion projects ready for each HTTP protocol` covers
  runtime translation, aggregate mutation, downstream ordering, and the rule
  that transport completion cannot regress `ready`.
- `all concurrent model exchanges must complete before ready` covers the
  aggregate's concurrency rule.
