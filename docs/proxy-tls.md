# ProxyTLS

ProxyTLS is an opt-in runtime service: an authenticated loopback CONNECT
proxy that every pane child inherits, with TLS interception for the hosts you
name and bounded capture of the exchanges it relays. It knows nothing about
agents. Agent state comes from hooks, the foreground process and the screen;
the proxy is a tool for looking at traffic.

## Try the proxy

This feature is optional and is not required for agent detection. Start with
[configuration basics](configuration.md); commands assume `telar` is on PATH.
Replace `api.example.com` below with a host whose traffic you intend to inspect.
Merge the `runtime.proxy` table into your config, or use this complete file:

```lua
return {
  api_version = 2,
  runtime = {
    proxy = {
      enabled = true,
      ca_dir = "state/proxy",
      capture = { enabled = false },
      intercept_hosts = { "api.example.com" },
    },
  },
}
```

The top workspace bar displays an interception badge for the entire time the
proxy is active, including while a pane is fullscreen.

Save/finish work in existing panes before restarting the runtime: stopping it
terminates its children. From an external terminal, run `telar server stop`,
then reopen Telar using the updated config. If you use `--config`, pass that
same path when reopening. New pane processes inherit the proxy and CA settings.
Check the running service with:

```sh
telar runtime status --json
```

Its proxy status should show that the service is active. Make a request using
the application you want to inspect from a new Telar pane. Hosts outside
`intercept_hosts` pass through as opaque tunnels; an empty list intercepts
nothing. Enabling the proxy alone does not create a browsable request archive.

The example leaves capture disabled. To process captured exchanges, enable
`runtime.proxy.capture.enabled` and configure a trusted
[exchange-listener plugin](plugins.md#exchange-listeners). Without one, completed
captures are consumed for metrics and are not persisted. Such a plugin can see
unredacted headers and bodies, including credentials.

For certificate errors, first check whether the application honors the CA
variables described below. Use [system trust](#system-trust) only for applications
that need it. The example's `ca_dir` is relative to `config.lua`; pass its resolved
absolute path with `--ca-dir` to every trust command so you do not configure a
different CA directory by mistake.

To disable interception, set `runtime.proxy.enabled = false`, then save work
and restart the runtime with that config. If you installed system trust,
uninstall that same authority with `telar proxy trust uninstall --ca-dir
/absolute/path/to/ca-dir`. Existing processes retain their inherited environment;
start new panes after changing the service.

The rest of this document explains trust, capture limits and connection behavior.

## Traffic path and trust

The runtime binds one loopback listener in ports 45100 through 45227. It
prefers the port it bound last time, so a process that inherited
`HTTPS_PROXY` keeps its destination across runtime restarts. Each runtime
remembers its own port in `proxy-port-<key>` inside the proxy directory, where
the key is a digest of its socket path; the file holds the port and that path.
Several runtimes of one account (the one you use, a development build, a test)
can share `ca_dir` without taking each other's ports, and a runtime that always
uses the same socket, as the default one does, always finds its own file. When
its port is taken, a runtime scans the range and skips the ports other runtimes
remember; it takes one of those only when nothing else is free, and then
removes the file of the runtime that lost it, so the directory holds at most
one file per port. A start also removes the file of any runtime whose socket
directory no longer exists, such as a deleted worktree's development runtime.

Earlier versions kept a single `proxy-port` for every runtime. Only the runtime
on the default socket, the one Telar starts when nothing names another, reads
it: it prefers that port and deletes the shared file once it binds the port and
records its own. A runtime that finds the port taken, or cannot write its own
file, leaves the shared file for its next start. Development runtimes ignore
it, so they neither take its port nor warn about it.

A stopping runtime closes its listening socket first, so nothing of it
listens on the port from then on. It then shuts down both sockets of every
connection, cancels each tunnel and waits for the tunnels to return, at most
2 seconds (`proxy.stop_timeout_ms`). A tunnel returns well before that
unless it is inside a call that neither a shutdown nor a cancellation
interrupts: name resolution on macOS is one. The runtime does not wait for
such a tunnel. It reports the limit in its log, finishes the rest of its
teardown and exits the process, where returning normally would wait for the
tunnel's thread. Nothing durable is pending by then: the session checkpoint
is written before the proxy stops, history is closed after it, and a tunnel
writes no file. The port file, the secret and the authority are written only
when the proxy starts.

Stopping the runtime closes the connections its children held open, and
those leave the port in TIME_WAIT for up to a minute. A plain bind refuses the
port meanwhile, which used to move a quickly restarted runtime to another
port. On Linux every proxy listener sets `SO_REUSEADDR`: there a TIME_WAIT
connection yields only to a bind by a socket with the option, as long as the
listener that accepted it had it too, and the option never binds over a socket
listening on the port, wildcard included. BSD and macOS bind plainly first,
because there the option would let a loopback socket shadow a process listening
on every address. When the remembered port is refused, they probe it with a
50 ms connection and bind again with `SO_REUSEADDR` only if the connection is
refused; a port that answers or stays silent counts as taken. Ports of the scan
are never probed. No listener sets `SO_REUSEPORT`. After an upgrade, the first
Linux restart can still find TIME_WAIT connections accepted by the old
listener, which did not set the option.

When the remembered port is held by another process, the runtime binds a
different one and says so. `telar runtime status` prints
`Proxy port: <port> (warning: remembered port <preferred> was held by another process; ...)`,
its JSON carries `proxy.port` and `proxy.preferred_port`, and in builds with
diagnostics every runtime telemetry line records `proxy_port` and
`proxy_preferred_port`. Processes that inherited the old port reach whatever
listens there, or nothing, until they are restarted from a pane. The new port
becomes the remembered one.

One secret authorizes every CONNECT. It lives in `proxy-secret` in the same
owner-only directory, created with mode 0600 on the first start and read on
every later one; deleting the file rotates it. A child presents it as the
Basic userinfo of the proxy URL, `http://telar:<secret>@127.0.0.1:<port>`,
which Telar puts in `HTTPS_PROXY`. The secret proves that the caller inherited
Telar's environment: it does not name a pane, and a daemon that outlives the
pane that started it keeps working until the secret rotates. A request without
it, or with a different one, gets `407`; a well-formed one with a malformed
target gets `400`. Counters distinguish the two rejections.

Runtimes that share `ca_dir` share the secret too, so a child that reaches
another runtime's port is accepted there rather than refused: its traffic goes
through that runtime's proxy, under that runtime's interception scope, and
what it captures reaches that runtime's tap plugins and whatever they record,
such as its command history. Per-runtime ports make that rare; they do not
forbid it. A per-runtime secret would turn it into a `407`, but it would not
isolate runtimes, since every process of the account can read the owner-only
directory, and it would break the processes that inherited the current secret.

Telar injects both forms of `HTTPS_PROXY` and process-local CA variables into
new panes. The generic variables cover OpenSSL, curl, Requests, Node.js, and
AWS clients. `GIT_SSL_CAINFO` covers Git, while
`CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` covers Google Cloud CLI clients that
otherwise select their own certifi bundle. Telar deliberately does not change
plaintext `HTTP_PROXY`. The local authority directory is mode 0700; its key,
certificate, and combined system root bundle are written atomically with mode
0600. Existing corrupt or partial authority files are not overwritten. Telar
uses a separate explicit command and a different authority for system trust;
enabling the proxy alone never changes an OS trust store.

Telar passes TLS through by default and intercepts only the hosts in
`intercept_hosts`, which is empty unless you set it. `*.example.com` matches
proper subdomains of `example.com`, but not the bare suffix; `*` matches every
hostname. Partial-label and embedded wildcards are rejected. The runtime
accepts 256 entries, canonicalizes and deduplicates them at startup, then
binary-searches exact rules and a suffix list ordered by reversed DNS labels
for every CONNECT hostname.

The top-bar shield is peach for exact-only interception and red when any
suffix or global wildcard expands the active scope. A yellow shield means the
system-trust authority remains installed while interception is off.

## Connections

The proxy admits 256 connections at once across every pane of the runtime
(`proxy.max_connections`), passthrough and intercepted alike. A connection
must send its whole CONNECT head, at most 16 KiB (`proxy.max_connect_head_bytes`,
a longer one is answered `431`), within 10 seconds. It must then reach its
origin and finish TLS within 30 seconds: resolving the host name and the TCP
connect to each resolved address wait only for what is left of that budget,
and stop at once when the proxy stops; a timeout is answered `504`, and a TLS
handshake still running at the deadline is shut down.

The system resolver cannot be interrupted. On macOS `getaddrinfo` returns
only when the resolver gives up, so no connection calls it on its own thread.
Each host name resolves on a worker thread of its own, and connections that
ask for the same name share that worker and its answer. A connection whose
name has not resolved at its deadline is answered `504` and frees its row at
that moment. The worker stays inside the resolver until it returns, and the
next connection to that name joins it instead of starting another, so a host
that does not resolve costs one thread however often its clients retry.

At most 64 host names resolve at once (`proxy.max_resolutions`). That bounds
what the resolver can hold while it does not answer: 64 threads with 512 KiB
of reserved stack each, and on macOS one descriptor per name. A connection
whose name finds all 64 taken by other names is answered
`503 Service Unavailable` without waiting and frees its row. It is `503` and
not `504` because the proxy is what ran out, and the origin was never tried.
A name keeps its first 32 addresses
(`proxy.max_resolved_addresses`), tried in the resolver's order. A host given
as a dotted IPv4 address needs no resolution and takes no worker, so it still
connects while every name is stuck.

Stopping the proxy does not wait for a worker still inside the resolver.
Resolutions live in a table that belongs to the process, not to the proxy,
and is never freed. A worker left behind touches only its row, and frees it
when the resolver returns.

A row is held only while both sides of its connection are there. Origin
sockets carry TCP keepalive: a connection silent for a minute is probed every
10 seconds, and six unanswered probes end it, so an origin that vanished
without closing, after a sleep or a network change, is noticed two minutes
after its last byte. An origin that answers its probes is never closed. Once
one side ends its stream, the child or the origin, the connection is half
closed: the proxy keeps relaying what the other side still sends and closes
the connection after a minute without a byte, in flight or not. Without that
bound a peer that never closes its side would keep the row until the table
filled.

At most 64 connections may still be sending their CONNECT head at once
(`proxy.max_unauthenticated`), so a local process that opens silent
connections can fill those rows and no others. Making room closes, in this
order: the oldest connection still sending its CONNECT head after a second,
far longer than a client needs; the HTTP/1.1 connection that has waited
longest, past a minute, for its next request; the connection silent longest,
past ten minutes, with nothing in flight. A connection with an exchange in
flight, from the first byte of an HTTP/1.1 request until its response ends or
while an HTTP/2 stream is open, is never closed to make room, however long a
model takes to answer; every byte relayed, HTTP/2 PING and WINDOW_UPDATE
included, marks a connection active. A new connection that finds no room is
answered `503 Service Unavailable`; the proxy drains what the client already
sent, for at most 20 ms, before closing, so the answer is not lost to a
reset. The accept loop waits for that drain, so a burst of refused
connections is answered at about 50 a second. At start the proxy raises the
process's soft descriptor limit to fit every slot's two sockets and one
descriptor per resolving name, but never
past 1024, the `FD_SETSIZE` of Linux and macOS, so no child the runtime
starts, however it starts it, can open a descriptor `select()` cannot hold;
children started on a pty also get back the exact limit the runtime
inherited. Accepting backs off when descriptors still run out.

For a host outside the allowlist, Telar responds with `200` and forwards the
TCP stream byte for byte. TLS remains end to end between the child and origin,
Telar captures nothing, and the child validates the origin with its normal
trust store.

The proxy connects to and validates the real origin first, carrying the
child's ALPN offer upstream, then mirrors only the selected protocol
downstream. It supports HTTP/1.1 and HTTP/2, and it relays both unchanged:
heads and bodies reach the other side as they arrived. In HTTP/1.1, request
bodies and origin responses run concurrently, so `100 Continue`, `103 Early
Hints`, and final responses that reject an unfinished upload reach the child
without deadlock. In HTTP/2 the relay forwards frames byte for byte and feeds a
copy of each bounded header block through an independent nghttp2 HPACK
inflater per direction; invalid framing, an HPACK error, or an oversized header
block disables capture for that direction while traffic continues unchanged.
A header block past 128 KiB (`proxy.h2.max_header_block_bytes`) and a stream
past the 128 the relay tracks (`proxy.h2.max_tracked_streams`) are counted and
reported by name.

An HTTP/1.1 head may be 64 KiB (`proxy.http1.max_head_bytes`), as large
cookies and bearer tokens need. A longer request head is answered `431` and a
longer response head `502`; neither is forwarded, and the connection ends. A
chunk-size line may be 1 KiB and a trailer line 8 KiB; a longer one ends the
body after its forwarded prefix.

## Exchange capture

`runtime.proxy.capture.enabled` copies each intercepted HTTP exchange for a
runtime-side consumer. It is off by default. HTTP/1.1 capture retains the
original head bytes and de-frames chunked bodies. HTTP/2 capture reconstructs
header fields and joins DATA payloads per stream. Capture does not alter the
bytes forwarded to either endpoint.

Request and response directions publish independent heap-owned halves. The
runtime pairs them by connection and stream ID, or releases a partial exchange
after `join_timeout_ms` when one direction never arrives. The request half
waits while its response streams, so the default, 15 minutes, covers a long
streamed model response. The join table holds 256 exchanges waiting for their
second half; a half that finds it full goes to the taps alone, as a partial
exchange. A half carries the protocol it travelled over, its host, method,
target, status and timestamps; it carries no secret and no pane.

Each head and body stops growing at `max_part_bytes` (16 MiB by default).
Request and response each get half of `max_exchange_bytes` (32 MiB), head and
body together, so a request cannot borrow what its response leaves unused. All
captures share `max_total_bytes` (128 MiB). The quota counts the storage the
capture buffers hold, charged before a buffer grows and released after the
copy, so it bounds their heap, copies while growing included; an idle
keep-alive connection waiting for its next request holds none. The
configuration refuses a `max_part_bytes` or
`max_exchange_bytes` above 64 MiB, a `max_total_bytes` above 1 GiB and a
`join_timeout_ms` above one hour. Truncation is recorded on the affected part
and reported under the bound that cut it. Queue publication is nonblocking;
queue saturation and shutdown free the abandoned buffers while traffic
continues. Captured buffers are erased before release.

When a tap worker is configured, `gzip`, `deflate`, `zstd`, and Brotli bodies
are decoded on the task that receives each half from the queue, never on a
relay task and never on the runtime's event loop, which only joins halves and
hands exchanges on by pointer. At most
two chained content codings are applied in reverse order. Decoded output
remains bounded by `max_part_bytes` and the half's share; an unknown or
malformed coding preserves the captured wire body and marks it as undecoded.
Completed exchanges are offered to supervised runtime-side Lua workers for
enabled packages with an exact `proxy.tap` grant. The workers share one copy
of each exchange; each encodes its own frame on its own thread. Each worker
has its own bounded queue and cannot delay proxy traffic. With no authorized
tap worker, the runtime records capture metrics and releases the exchange
without decoding it.

The memory capture can hold at once, with the defaults:

- capture buffers, queued, joined and in the tap's queues included, within
  `max_total_bytes`: 128 MiB;
- frames tap workers are sending, within the tap's 128 MiB budget
  (`plugins.tap.max_held_bytes`), which also counts the queued exchanges;
- one body being decoded: a scratch of `max_part_bytes`, the decoded copy
  and a 64 KiB inflate window, about 32 MiB, outside the quota;
- about 8.8 KiB of bookkeeping per half, outside the quota: two per
  intercepted HTTP/1.1 connection and one per captured HTTP/2 stream;
- per live connection, its tunnel threads' stacks: a 16 KiB CONNECT head,
  up to 64 KiB of HTTP/1.1 head and 8 KiB of trailer line when one is that
  long, 16 or 32 KiB of relay buffers per direction, plus a TLS session of
  about 66 KiB when intercepted.

At worst that is about 300 MiB beyond the connections' own cost, reached only
while taps are slower than the traffic they read.

The `proxy.tap` capability is full trust: it receives unredacted headers and
bodies, including authorization and cookie values. Grant it only to plugin
code that may read all intercepted traffic.

## Lua tap boundary

An authorized tap package runs in an isolated long-lived Lua child behind its
own bounded queue. The tunnel publishes an owned exchange snapshot; the worker
receives an immutable value and returns typed notification effects. Zig
validates the complete batch and its capabilities before applying anything.
Timeouts, VM errors, stale identities, and full queues discard extension work.
A Lua closure never enters the runtime loop, a TLS session, or a tunnel actor,
and it never receives a Zig pointer. See [Proxy tap](flows/proxy-tap.md).

## Counters

Bounded counters distinguish rejected authentication, upstream connection
failures, each TLS interception stage, HTTP/2 decode failures, passthrough
connections, and capture starts, truncations, skipped halves, queue drops and
decode failures. No metric retains the destination hostname or payload.
Runtime telemetry exposes them with a `proxy_` prefix.

The proxy's threads only count the limits they reach. Once a second the
runtime's maintenance tick reports every limit whose count grew with the
[limit notice](flows/limit-reached.md): `proxy.max_connections`,
`proxy.max_connect_head_bytes`, `proxy.connect_head_timeout_ms`,
`proxy.establish_timeout_ms`, `proxy.max_resolutions`,
`proxy.max_resolved_addresses`, `proxy.http1.max_head_bytes`,
`proxy.http1.max_chunk_line_bytes`, `proxy.http1.max_trailer_line_bytes`,
`proxy.max_unauthenticated`, `proxy.h2.max_header_block_bytes`,
`proxy.h2.max_tracked_streams`,
`proxy.capture.h2_stream_slots`, `proxy.capture.queue_capacity`,
`proxy.capture.max_part_bytes`, `proxy.capture.max_exchange_bytes` and
`proxy.capture.max_total_bytes`, and for the taps
`plugins.tap.queue_depth`, `plugins.tap.max_held_bytes`,
`plugins.tap.reply_timeout_ms` and `plugins.tap.restart_limit`. The event
loop reports `proxy.capture.joiner_capacity` where it joins halves, and the
runtime's teardown reports `proxy.stop_timeout_ms` when it stops without a
tunnel.

## System trust

ProxyTLS works without changing system trust because Telar injects CA paths
into panes. Applications that ignore those variables require an explicit trust
installation:

```sh
telar proxy trust status
telar proxy trust install
telar proxy trust uninstall
```

On macOS, Telar installs into the current user's login keychain without
`sudo`. On Linux the backend is mandatory: use `--linux
update-ca-certificates` on Debian-family systems or `--linux trust` on systems
that provide p11-kit. Telar prints each argv before it starts the process. It
does not invoke a shell.

The command creates `ca-system-key.pem` and `ca-system-cert.pem`, separate from
the private CA used by default. The system authority is valid for 30 days. A
server start replaces it when less than one day remains, removes the prior
recorded certificate from the selected trust store, and records the new backend,
fingerprint, and store path in `trust-install.json`. The directory is mode
0700; CA files and the record are mode 0600. A malformed record stops install
and uninstall because Telar can no longer prove which certificate it owns.

`--ca-dir PATH` selects the same absolute directory as `runtime.proxy.ca_dir`.
Without it, the command uses `$XDG_DATA_HOME/telar/proxy` or
`$HOME/.local/share/telar/proxy`. Keep both settings aligned when config uses a
custom path.

Firefox may use its own certificate store. The command prints the certificate
path for manual import and does not modify Firefox profiles. Uninstall uses the
recorded identity and destination, so it does not remove an unrelated
certificate.

## Build dependency

The runtime links `libnghttp2` for HPACK decoding and encoding and
`libbrotlidec` for captured Brotli bodies. Both are compiled from the sources
pinned in `build.zig.zon` and linked statically, so no installation is needed.
`zig build -Dnghttp2=/path/to/prefix` and `-Dbrotli=/path/to/prefix` link a
system installation instead; see [packaging](packaging.md#native-libraries).
