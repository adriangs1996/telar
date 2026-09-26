---
status: accepted
---

# Decouple the proxy from agents

Supersedes [0004](0004-keep-proxy-credentials-behind-the-proxy-root.md).

The observation proxy grew up as a way to learn what an agent was doing from
its model traffic: an SSE decoder per provider, inference-route
classification, a lifecycle observation queue into the agent tracker, and a
credential per pane generation so the traffic could be attributed to a pane.
That attribution was the reason the credential had to die with its pane, and
it is why a daemon that inherited `HTTPS_PROXY` broke on the first pane close
or runtime restart. It was also wrong whenever one process served several
panes.

## Decision

Agents are followed only through their official hooks, the foreground process
and the screen. The proxy stops understanding traffic: no provider dialects,
no SSE decoding, no lifecycle observations, no agent evidence or command
records from tap plugins. What remains is a generic authenticated tunnel with
TLS interception for the hosts the user names, exchange capture, and Lua taps
that may return notifications.

Authorization is separated from attribution. One secret per proxy directory,
persisted with mode 0600 and created on first start, admits every child of
the runtime; the listener prefers its last port. A child keeps its proxy
across pane closes and runtime restarts. Deleting the secret file rotates it.

Interception intercepts nothing by default.

## Consequences

The status a hook does not report is gone: a model API failure no longer
projects `failed`, and an agent without hooks has only process and screen
evidence. To cover long model turns that fire no hook, a `working` report
lives ten minutes instead of two; a `settling` report keeps the short expiry.

Captured exchanges name no pane. A future per-pane attribution needs a signal
from the process, not from the proxy.

The runtime keeps no proxy registry, revokes nothing on pane exit and carries
no `CredentialId`; the runtime asks the proxy for a child environment and
receives captured halves, nothing else.
