---
status: accepted
---

# Keep proxy credentials behind the proxy root

The runtime needs to launch pane children through the observation proxy, but a
credential is proxy-owned authorization rather than pane state. Exposing it to
the runtime couples pane lifecycle to proxy identity, TLS and middleware
representation and makes accidental retention possible.

## Decision

`proxy/root.zig` exposes lifecycle, pane registration and revocation,
observations and a metrics snapshot. HTTP/1.1, HTTP/2, TLS, identity,
middleware, credential storage and queue representation remain private.

The runtime registers and revokes only by `PaneKey`. Registration returns an
owned, bounded `PaneEnvironment` that exposes the child environment but never
the credential. The environment exists only through spawn; the credential
remains in the proxy registry until launch abort or retirement of that pane
generation.

Revocation rejects new connections and discards queued or late observations for
that generation. An established tunnel continues forwarding bytes so
observation lifecycle cannot disrupt the interactive path, but it produces no
further observations.

## Consequences

`Pane` does not store a proxy credential. Launch rollback revokes by `PaneKey`,
and observations crossing the public seam contain `PaneKey` rather than
authorization material. Integration tests must prove registration, launch
environment disposal, revocation, stale-event rejection and forwarding under a
saturated observation queue.
