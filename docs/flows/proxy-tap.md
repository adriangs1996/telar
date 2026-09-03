# Proxy tap

This flow begins after ProxyTLS has copied, decoded and joined a complete
exchange. It never runs on the relay task.

```text
proxy capture joiner
        |
        | owned CaptureExchange
        v
plugins.Service.submit
        |
        | length-prefixed immutable exchange frame
        v
bounded per-plugin queue (64, drop oldest)
        |
        v
long-lived `telar tap-worker` child
        |
        | sandboxed Lua on_exchange(exchange)
        v
bounded typed effect frame
        |
        v
RuntimeEvent.plugin_effects
        |
        v
plugin_effects.Adapter
        |
        +-- exact generation, plugin ID and digest check
        +-- declared and granted capability check
        +-- notification publication
        +-- low/medium agent evidence
        `-- command persistence (history effect owner)
```

The runtime starts only enabled packages whose exact digest grant includes
`proxy.tap`. Before spawn, the CLI copies each package into a private `0700`
directory and verifies the copied digest. The child runs with `/` as its working
directory and an empty environment. Its Lua VM exposes restricted base, string,
table, math, coroutine and UTF-8 libraries plus local package modules and the
typed `telar` API; it exposes no `io`, `os`, `package`, native loader, runtime
socket, or inherited credentials.

Every exchange carries a monotonic event ID and the startup configuration
generation. Replies echo the event ID. The runtime rejects trailing protocol
bytes, stale identity, undeclared effects and ungranted effects before applying
the batch. A callback error is returned as a bounded error frame, leaving the
worker available for the next exchange. Transport failure restarts the child;
five failures inside ten minutes disable that worker until the runtime restarts.

Shutdown first stops proxy production, then closes worker queues and kills each
child and its descendants. Captured buffers and protocol frames are scrubbed by
their single owner before release.
