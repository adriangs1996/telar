# ProxyTLS

ProxyTLS is an opt-in runtime service: an authenticated loopback CONNECT
proxy that every pane child inherits, with TLS interception for the hosts you
name and bounded capture of the exchanges it relays. It knows nothing about
agents. Agent state comes from hooks, the foreground process and the screen;
the proxy is a tool for looking at traffic.

Enable it in `config.lua` and restart the long-lived runtime:

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

## Traffic path and trust

The runtime binds one loopback listener in ports 45100 through 45227. It
prefers the port it bound last time, recorded in `proxy-port` inside the proxy
directory, so a process that inherited `HTTPS_PROXY` keeps its destination
across runtime restarts. Only when that port is taken does it scan the range.

Stopping the runtime closes the connections its children held open, and
those leave the port in TIME_WAIT for up to a minute. A plain bind refuses the
port meanwhile, which used to move a quickly restarted runtime to another
port. When a plain bind fails and nothing answers a connection on the port,
the runtime binds again with `SO_REUSEADDR`. It never sets `SO_REUSEPORT`, and
the probe keeps it from shadowing a process that listens on every address,
which BSD allows under `SO_REUSEADDR`.

One secret authorizes every CONNECT. It lives in `proxy-secret` in the same
owner-only directory, created with mode 0600 on the first start and read on
every later one; deleting the file rotates it. A child presents it as the
Basic userinfo of the proxy URL, `http://telar:<secret>@127.0.0.1:<port>`,
which Telar puts in `HTTPS_PROXY`. The secret proves that the caller inherited
Telar's environment: it does not name a pane, and a daemon that outlives the
pane that started it keeps working until the secret rotates. A request without
it, or with a different one, gets `407`; a well-formed one with a malformed
target gets `400`. Counters distinguish the two rejections.

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

## Exchange capture

`runtime.proxy.capture.enabled` copies each intercepted HTTP exchange for a
runtime-side consumer. It is off by default. HTTP/1.1 capture retains the
original head bytes and de-frames chunked bodies. HTTP/2 capture reconstructs
header fields and joins DATA payloads per stream. Capture does not alter the
bytes forwarded to either endpoint.

Request and response directions publish independent heap-owned halves. The
runtime pairs them by connection and stream ID, or releases a partial exchange
after `join_timeout_ms` when one direction never arrives. A half carries the
protocol it travelled over, its host, method, target, status and timestamps;
it carries no secret and no pane.

Each head and body stops growing at `max_part_bytes`, each exchange is bounded
by `max_exchange_bytes`, and all active captures share `max_total_bytes`.
Truncation is recorded on the affected part. Queue publication is nonblocking;
quota exhaustion, queue saturation, and shutdown free the abandoned buffers
while traffic continues. Captured buffers are erased before release.

The runtime decodes `gzip`, `deflate`, `zstd`, and Brotli bodies after queue
delivery, never on a relay task. At most two chained content codings are
applied in reverse order. Decoded output remains bounded by
`max_part_bytes`; an unknown or malformed coding preserves the captured wire
body and marks it as undecoded. Completed exchanges are offered to supervised
runtime-side Lua workers for enabled packages with an exact `proxy.tap` grant.
Each worker has its own bounded queue and cannot delay proxy traffic. With no
authorized tap worker, the runtime records capture metrics and releases the
exchange.

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
connections, and capture starts, truncations, quota skips, queue drops and
decode failures. No metric retains the destination hostname or payload.
Runtime telemetry exposes them with a `proxy_` prefix.

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
