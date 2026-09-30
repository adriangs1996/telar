# Proxy tap

This flow begins after ProxyTLS has copied, decoded and joined a complete
exchange. It never runs on the relay task.

```text
proxy capture joiner (ProxyRuntime.acceptCapture / expireCaptures)
        |
        | owned capture Exchange
        v
plugins Service.submit
        |
        | length-prefixed immutable exchange frame
        v
bounded per-plugin queue (64, drop oldest; 256 MiB of frames across all)
        |
        v
long-lived `telar tap-worker` child
        |
        | sandboxed Lua on_exchange(exchange)
        v
bounded typed effect frame
        |
        v
runtime Event.plugin_effects
        |
        v
proxy_tap.receive
        |
        +-- exact generation, plugin ID and digest check
        +-- declared and granted capability check
        `-- notification publication
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
worker available for the next exchange. A callback runs for at most two
seconds; the runtime waits three for its reply, so a callback stopped at its
deadline still replies. A missed reply or a transport failure restarts the
child; five restarts inside ten minutes disable that worker until the runtime
restarts. Frames that do not fit the queue or the shared 256 MiB budget are
dropped. The maintenance tick reports each of these limits with the limit
notice: `plugins.tap.queue_depth`, `plugins.tap.max_queued_bytes`,
`plugins.tap.reply_timeout_ms` and `plugins.tap.restart_limit`.

Shutdown first stops proxy production, then closes worker queues and kills each
child and its descendants. Captured buffers and protocol frames are scrubbed by
their single owner before release.

A tap returns notifications only. Host tests round-trip the effect frame,
reject the retired command and evidence tags, and prove the capability checks
for every effect.
