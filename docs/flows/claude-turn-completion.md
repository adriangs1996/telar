# Claude turn completion

A Claude model exchange starts when an intercepted `POST /v1/messages` body is
valid JSON with top-level `stream: true` and a non-empty top-level `tools`
array. The route alone is insufficient because Claude Code uses the same
endpoint for startup probes and helper requests. Telar keeps the agent
`working` until the provider protocol explicitly reports `end_turn`.
Finishing the HTTP response is insufficient because Claude may execute a local
tool and start another model exchange.

## Flow

```text
Claude POST /v1/messages body
        |
ProxyTLS HTTP/1.1 or HTTP/2 relay
        |
bounded incremental JSON classifier
        |
request_started -> Agent Tracker -> working
        |
Accept-Encoding: identity negotiation
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

The request classifier reads borrowed payload fragments while the relay owns
their lifetime and retains no prompts or tool inputs. Its result cannot alter
forwarding. It validates the complete JSON document and fails closed as
auxiliary when the body is malformed, duplicated at a relevant field, deeper
than 64 levels, or larger than 8 MiB. HTTP/2 keeps independent bounded decoder
state per stream.

Before forwarding a Claude `POST /v1/messages` head, the native transport
transform replaces `Accept-Encoding` with `identity`. This keeps observation
allocation-free and avoids decompressing a second copy while Claude Code still
receives the origin's response normally. Other routes, providers, response
heads, and trailers are preserved. A server that ignores the negotiation and
returns a content coding remains unobservable rather than feeding compressed
bytes to the SSE decoder.

`service.HttpResponseObserver.observe` handles HTTP/1.1 response fragments.
`service.H2EventObserver.emit` handles HTTP/2 DATA events. Both feed borrowed
payload bytes from successful, identity-encoded SSE responses to
`provider.ResponseObserver`.
HTTP/1.1 restricts this to inference-candidate routes. HTTP/2 keeps decoder
state isolated by stream, and unmatched completion evidence cannot mutate the
agent aggregate. Response headers establish only whether the payload is safe
to decode as SSE; the event body remains the completion authority. The
provider interpreter requires valid SSE framing, the matching event name,
valid JSON, and the exact `end_turn` reason. Forwarding never depends on this
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

- `HTTP1 Claude request bodies refine route candidates before publication`
  covers startup, bodyless, and primary request classification at the service
  boundary.
- `HTTP2 Claude request bodies refine interleaved route candidates per stream`
  covers concurrent body classification and stream identity.
- `Claude inference requests negotiate identity encoding` and
  `service negotiates identity encoding for Claude message requests` cover the
  provider rule and its installation in the live transform pipeline.
- `HTTP1 Claude SSE publishes provider turn completion after forwarding`
  covers HTTP framing, byte forwarding, SSE parsing, provider interpretation,
  publication, and queue delivery.
- `HTTP2 observer exposes request DATA across every two-chunk split` and
  `HTTP2 observer finishes a bodyless request across every two-chunk split`
  prove request-body and end-of-request delivery at arbitrary boundaries.
- `HTTP2 observer exposes DATA payload across every two-chunk split` proves
  response payload delivery before transport completion.
- `HTTP2 final DATA publishes Claude completion before transport completion`
  covers provider interpretation, exact stream identity, publication, and
  stream cleanup.
- `Claude provider completion projects ready for each HTTP protocol` covers
  runtime translation, aggregate mutation, downstream ordering, and the rule
  that transport completion cannot regress `ready`.
- `all concurrent model exchanges must complete before ready` covers the
  aggregate's concurrency rule.
