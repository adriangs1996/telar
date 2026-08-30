# ProxyTLS

ProxyTLS is an opt-in runtime service that observes HTTPS request lifecycles
without depending on Codex or Claude Code harness hooks. Its first consumer is
agent state in the sidebar. The native proxy also has a bounded semantic
request-head transformation boundary for future extensions. Production does
not install a transformer today, so enabling ProxyTLS alone never alters HTTP.

Enable it in `config.lua` and restart the long-lived runtime:

```lua
return {
  api_version = 2,
  runtime = {
    proxy = {
      enabled = true,
      ca_dir = "state/proxy",
      passthrough_hosts = { "updates.example.com" },
    },
  },
}
```

The bottom status bar displays `TLS PROXY` for the entire time interception is
active, including while a pane is fullscreen.

## Traffic path and trust

The runtime binds one loopback listener in ports 45100 through 45227. Each pane
gets a random 128-bit proxy capability bound to its pane ID and generation.
The listener accepts only capabilities currently registered by a running pane;
process exit revokes one before its pane storage is released. Runtime event
handling validates the same generation and token again before changing agent
state.

Telar injects both forms of `HTTPS_PROXY` and process-local CA variables into
new panes. The generic variables cover OpenSSL, curl, Requests, Node.js, and
AWS clients. `GIT_SSL_CAINFO` covers Git, while
`CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` covers Google Cloud CLI clients that
otherwise select their own certifi bundle. Telar deliberately does not change
plaintext `HTTP_PROXY`. The local authority directory is mode 0700; its key,
certificate, and combined system root bundle are written atomically with mode
0600. Existing corrupt or partial authority files are not overwritten. Telar
never installs this CA in the system trust store.

Some clients validate through a platform trust API and cannot consume a
process-local CA. Telar therefore has an exact-host passthrough policy.
`api.github.com`, used by lazygit's internal GitHub requests, and
`ab.chatgpt.com`, used by Codex on macOS, are built in. Entries in
`passthrough_hosts` extend that list; wildcards and suffix matches are rejected.
The runtime accepts 256 configured entries, canonicalizes and deduplicates them
at startup, then uses binary search for every CONNECT hostname.
The CONNECT request still requires a live pane capability, but after the `200`
response Telar forwards the TCP stream byte for byte. TLS remains end to end
between the child and origin, and Telar produces no HTTP lifecycle observation
for that connection. The child validates the origin with its normal trust
store.

The proxy connects to and validates the real origin first, carrying the
child's ALPN offer upstream, then mirrors only the selected protocol
downstream. It supports HTTP/1.1 and HTTP/2.

In HTTP/1.1, the default path relays each head and framed body unchanged.
Request bodies and origin responses run concurrently, so `100 Continue`, `103
Early Hints`, and final responses that reject an unfinished upload reach the
child without deadlock. A registered transformer may change the method,
request target, status, or headers. Telar validates and reserializes the whole
head. An invalid effect, an oversized result, changed body framing, changed
upgrade semantics, or changed connection-close semantics preserves the exact
original head bytes.

In HTTP/2, the observation-only path relays frames byte for byte and feeds a
copy of each bounded header block through an independent nghttp2 HPACK inflater
per direction. Invalid framing, an HPACK error, or an oversized header block
disables metadata inspection for that direction; traffic continues unchanged.

Installing a transformer selects the semantic-head path. Each direction then
owns an independent HPACK inflater and deflater. Telar buffers only HEADERS,
PUSH_PROMISE, and CONTINUATION blocks, validates their pseudo-headers, applies
one atomic effect batch at a time, and emits a new bounded header block that
respects the receiving peer's SETTINGS. DATA, SETTINGS, PING, WINDOW_UPDATE,
RST_STREAM, GOAWAY, stream IDs, and flow control remain end to end. Padding may
be removed when a transformed header block is emitted; HEADERS priority fields
and PUSH_PROMISE promised-stream IDs are preserved.

A rejected HTTP/2 effect batch preserves the original semantic fields and
re-encodes them through the proxy's current HPACK context. Once that context
has diverged from the source, a malformed or oversized compressed block cannot
be copied safely to the receiver. The transformed connection therefore fails
explicitly instead of forwarding bytes against the wrong dynamic table. This
failure mode exists only when a transformer has been registered.

## Transformation contract

The native boundary accepts at most eight immutable transformers. A callback
receives an owned, immutable snapshot with pane identity and generation, provider,
protocol, direction, header kind, connection ID, stream ID, and header fields.
It returns no more than 32 typed `set` or `remove` effects using at most 8 KiB.
The shared representation is bounded to 256 fields and 128 KiB. HTTP/1.1 heads
have a stricter 32 KiB wire limit; encoded HTTP/2 output is bounded to 256 KiB.
HPACK dynamic tables are capped at 128 KiB per direction. A callback error or
invalid complete batch applies nothing from that callback. Pipelines become
immutable before the listener starts.

HTTP/2 transformations enforce lowercase field names, pseudo-header order and
uniqueness, CONNECT rules, response status syntax, forbidden connection
headers, and `te: trailers`. A transformer cannot insert a new pseudo-header;
it can replace or remove an existing one only when the final head remains
valid. `content-length` values remain unchanged because bodies are not part of
this contract. Response status changes must retain their informational,
bodyless, or regular response semantics.

Header values are not persisted or copied to the observation queue. Bodies
stream unchanged and are not exposed to transformers. Arbitrary body mutation,
especially a change in length, is a different capability: HTTP/2 would have to
terminate flow control, and Lua exposure would first need explicit secret
redaction, retention, timeout, and memory policies.

Known secret names such as `authorization`, `cookie`, and `x-api-key` remain
marked sensitive even if a native transformer says otherwise, so HPACK never
indexes a replacement accidentally. Native transformers are trusted runtime
code and can see the live snapshot. A future Lua adapter must redact sensitive
values before constructing Lua data unless the user grants a separate secret
capability.

## Agent state

Hosts below `anthropic.com` identify Claude Code and hosts below `openai.com`
or `chatgpt.com` identify Codex. Only `POST /v1/messages` belongs to Claude;
only `POST /v1/responses` and `POST /backend-api/codex/responses` belong to
Codex. Queries do not change route ownership. Cross-provider routes, unknown
hosts, and other requests are auxiliary and do not drive agent lifecycle.

An inference request start, response data, or successful response completion
means `working`: one completed model exchange may be followed by local tool
execution and another model request within the same agent turn. HTTP/1.1 error
responses, HTTP/2 stream resets, and failures while connecting or establishing
TLS mean `failed`. HTTP/2 response status is decoded from HPACK, so a completed
response with status 400 or greater also means `failed`.

HTTP/2 lifecycle state is keyed by protocol, connection ID, and stream ID.
Completing every active stream still does not prove that the agent turn ended.
A connection-level failure settles every remaining stream on that connection,
while a graceful duplicate sentinel after all streams completed does not
overwrite their result. Both the protocol observer and agent store track at
most 128 concurrent streams per bounded record.

Network evidence cannot see a terminal permission dialog, so the observation
worker also recognizes bounded presentation hints found in Codex, Claude Code,
and herdr behavior. Permission and confirmation prompts produce `blocked` and
override proxy activity. Working text overrides an early response completion.
Claude becomes `ready` only when the emulated terminal's current screen has a
visible cursor immediately after its `❯` input prompt. The raw PTY byte stream
cannot establish that state because a later terminal control sequence may have
erased or moved the glyph. Claude identity must already be known from the
foreground process, proxy, or branding; a bare `❯` never establishes it.
Codex's explicit branded input prompt confirms `ready` in one sample. Generic
prompts without established agent identity are discarded.
Evidence expires, and pane generation plus process and history-session
identity prevent a late event from attaching to a reused pane.

These are sidebar hints, not agent authority. A heuristic never approves a
command, resumes a session, kills a process, or generates terminal input.
Observation values contain only connection, stream, protocol, provider, phase,
status code, pane identity, and timestamps. Queue saturation drops
observations, never traffic.

Bounded counters distinguish rejected authentication, upstream connection
failures, each TLS interception stage, HTTP/2 decode failures, and passthrough
connections. They never retain the destination hostname or payload.

## Lua middleware boundary

The runtime currently installs one native observer whose only operation is a
nonblocking enqueue into the 256-event observation queue. Lua callbacks are not
accepted in `runtime.proxy` yet.

The future adapter must run an isolated Lua worker behind a bounded queue. The
tunnel copies a value snapshot to that worker; the worker returns typed
semantic effects; Zig validates the complete batch. Timeouts, VM errors, and
full queues discard the extension result. A Lua closure never enters the
runtime loop, a TLS session, or a tunnel actor, and it never receives a Zig
pointer. Registering a new immutable pipeline generation happens before it can
accept connections.

## System trust remains unchanged

Installing Telar's CA into Keychain or another system trust store remains a
separate user decision and is outside the current implementation. The built-in
passthrough hosts do not require that installation.

## Build dependency

The runtime links the system `libnghttp2` for HPACK decoding and encoding. The
default prefix is `/opt/homebrew/opt/libnghttp2` on Apple Silicon,
`/usr/local/opt/libnghttp2` on Intel macOS, and `/usr` elsewhere. Override it
with `zig build -Dnghttp2=/path/to/prefix`.
