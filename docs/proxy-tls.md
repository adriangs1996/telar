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
      capture = { enabled = false },
      intercept_hosts = {
        "api.anthropic.com",
        "api.openai.com",
        "chatgpt.com",
      },
    },
  },
}
```

The top workspace bar displays an interception badge for the entire time the
proxy is active, including while a pane is fullscreen.

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
uses a separate explicit command and a different authority for system trust;
enabling the proxy alone never changes an OS trust store.

Telar passes TLS through by default and intercepts only its host allowlist.
The defaults cover the model APIs used by Claude Code and Codex:
`api.anthropic.com`, `api.openai.com`, and `chatgpt.com`. Setting
`intercept_hosts` replaces those defaults, so an empty array disables all TLS
interception while retaining the authenticated proxy tunnel. `*.example.com`
matches proper subdomains of `example.com`, but not the bare suffix; `*`
matches every hostname. Partial-label and embedded wildcards are rejected. The
runtime accepts 256 entries, canonicalizes and deduplicates them at startup,
then binary-searches exact rules and a suffix list ordered by reversed DNS
labels for every CONNECT hostname.

The top-bar shield is peach for exact-only interception and red when any
suffix or global wildcard expands the active scope. A yellow shield means the
system-trust authority remains installed while interception is off.

Every CONNECT request still requires a live pane capability. For a host outside
the allowlist, Telar responds with `200` and forwards the TCP stream byte for
byte. TLS remains end to end between the child and origin, Telar produces no
HTTP lifecycle observation, and the child validates the origin with its normal
trust store.

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
receives an owned, immutable snapshot with pane identity and generation, API
dialect, protocol, direction, header kind, connection ID, stream ID, and header
fields.
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

Header values are not persisted or copied to the lifecycle observation queue.
When exchange capture is explicitly enabled, original heads and de-framed
bodies are copied into a separate bounded capture queue. Bodies still stream
unchanged and are not exposed to transformers. Arbitrary body mutation,
especially a change in length, is a different capability: HTTP/2 would have to
terminate flow control, and Lua exposure would first need explicit secret
redaction, retention, timeout, and memory policies.

Known secret names such as `authorization`, `cookie`, and `x-api-key` remain
marked sensitive even if a native transformer says otherwise, so HPACK never
indexes a replacement accidentally. Native transformers are trusted runtime
code and can see the live snapshot. The `proxy.tap` capability is also full
trust: it receives unredacted headers and bodies, including
authorization and cookie values. Grant it only to plugin code that may read all
intercepted traffic.

## Exchange capture

`runtime.proxy.capture.enabled` copies each intercepted HTTP exchange for a
runtime-side consumer. It is off by default. HTTP/1.1 capture retains the
original head bytes and de-frames chunked bodies. HTTP/2 capture reconstructs
header fields and joins DATA payloads per stream, including unknown API
dialects. Capture does not alter the bytes forwarded to either endpoint.

Request and response directions publish independent heap-owned halves. The
runtime pairs them by connection and stream ID, or releases a partial exchange
after `join_timeout_ms` when one direction never arrives. Pane identity and
generation survive the handoff; the proxy credential token does not.

Each head and body stops growing at `max_part_bytes`, each exchange is bounded
by `max_exchange_bytes`, and all active captures share `max_total_bytes`.
Truncation is recorded on the affected part. Queue publication is nonblocking;
quota exhaustion, queue saturation, credential revocation, and shutdown free
the abandoned buffers while traffic continues. Captured buffers are erased
before release.

The runtime decodes `gzip`, `deflate`, `zstd`, and Brotli bodies after queue
delivery, never on a relay task. At most two chained content codings are
applied in reverse order. Decoded output remains bounded by
`max_part_bytes`; an unknown or malformed coding preserves the captured wire
body and marks it as undecoded. Completed exchanges are offered to supervised
runtime-side Lua workers for enabled packages with an exact `proxy.tap` grant.
Each worker has its own bounded queue and cannot delay proxy traffic. With no
authorized tap worker, the runtime records capture metrics and releases the
exchange.

The shipped
[`examples/plugins/agent-commands`](../examples/plugins/agent-commands)
listener demonstrates classification in Lua. It reconstructs command
arguments from Anthropic and OpenAI streaming events and returns typed history
effects; Telar does not embed those provider event formats in the proxy.

## Agent state

The proxy classifies by API dialect (`provider.ApiDialect`), never by agent.
Hosts below `anthropic.com` speak `anthropic_messages`; hosts below
`openai.com` or `chatgpt.com` speak `openai_responses`. Which agent process
drives an exchange is the runtime's decision: a dialect implies its native
built-in agent (Claude Code, Codex) only while no process has claimed the
pane, so Pi talking to Anthropic is still Pi. `POST /v1/messages` is an
Anthropic inference candidate. Telar publishes it as an inference request only
when its complete JSON body has top-level `stream: true` and a non-empty
top-level `tools` array. Claude Code also sends startup probes and helper
requests to that route, so the route cannot establish `working` by itself.
Only `POST /v1/responses` and `POST /backend-api/codex/responses` belong to
the OpenAI dialect. Queries do not change route ownership. Cross-dialect
routes, unknown hosts, and other requests are auxiliary and do not drive agent
lifecycle.

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

For a successful candidate response, the proxy inspects forwarded payload
fragments without retaining them. A native request transform replaces
`Accept-Encoding` with `identity` for Claude `POST /v1/messages`, allowing the
SSE decoder to inspect the forwarded representation directly without a second
decompression path. The transform preserves all other routes, other
providers, response heads, and bodies. Successful response headers must still
describe identity-encoded `text/event-stream`; an origin that ignores the
negotiation remains unobservable.

A Claude `message_delta` whose JSON type also equals `message_delta` and whose
`stop_reason` is `end_turn` publishes `provider_turn_completed`. The agent
becomes `ready` only after every active model exchange has produced that
outcome. Truncated or malformed events and continuation outcomes such as
`tool_use` do not complete the turn.

Network evidence cannot see a terminal permission dialog, so the observation
worker also recognizes bounded presentation hints found in Codex, Claude Code,
and herdr behavior. Permission and confirmation prompts produce `blocked` and
override proxy activity. Working text overrides an early response completion.
Claude's emulated terminal screen can independently confirm `ready` when it has
a visible cursor immediately after its `❯` input prompt. The raw PTY byte stream
cannot establish that state because a later terminal control sequence may have
erased or moved the glyph. Claude identity must already be known from the
foreground process, proxy, or branding; a bare `❯` never establishes it.
Manifest phrases are matched on that emulated screen as well, so Codex's
branded input prompt, which stays visible while a turn runs, confirms `ready`
only once the status line above it is gone. Generic prompts without
established agent identity are discarded.
Evidence expires, and pane generation plus process and history-session
identity prevent a late event from attaching to a reused pane.

These are sidebar hints, not agent authority. A heuristic never approves a
command, resumes a session, kills a process, or generates terminal input.
Observation values contain only connection, stream, protocol, dialect, phase,
status code, pane identity, and timestamps. One fixed 256-event channel checks
the pane credential both before publication and before delivery. Revocation
therefore removes queued authority as well as rejecting later observations.
Saturation or closure drops publication, never traffic; a normal close drains
already-buffered observations before receivers see `error.Closed`.

Bounded counters distinguish rejected authentication, upstream connection
failures, each TLS interception stage, HTTP/2 decode failures, and passthrough
connections. Observation metrics expose reserved delivery depth, its high-water
mark, and publications lost to capacity or closure. Rejected and subsequently
revoked credentials do not increment the loss counter because they were never
eligible for delivery. No metric retains the destination hostname or payload.

Runtime telemetry exposes five Claude-specific counters without retaining
headers or response data:

- `proxy_claude_inference_requests` counts body-classified `/v1/messages`
  starts.
- `proxy_claude_sse_payload_fragments` counts response payload fragments
  examined by the SSE interpreter.
- `proxy_claude_turn_completions` counts verified `end_turn` outcomes.
- `proxy_claude_successful_responses` counts successful transport completions.
- `proxy_claude_failure_observations` counts published failure outcomes.

If requests increase but SSE fragments do not, inspect response status, body
framing, content coding, and HTTP/2 decode failures; the origin may have ignored
identity negotiation. If fragments increase without turn completions, the
received SSE did not contain a valid, non-truncated Claude `end_turn`. If turn
completions increase while the agent remains `working`, compare observation
queue loss and active concurrent model exchanges; provider interpretation has
already succeeded.

## Lua tap boundary

The runtime keeps lifecycle and exchange capture on separate nonblocking
queues. An authorized tap package runs in an isolated long-lived Lua child
behind its own bounded queue. The tunnel publishes an owned exchange snapshot;
the worker receives an immutable value and returns typed semantic effects. Zig
validates the complete batch and its capabilities before applying anything.
Timeouts, VM errors, stale identities, and full queues discard extension work.
A Lua closure never enters the runtime loop, a TLS session, or a tunnel actor,
and it never receives a Zig pointer. See [Proxy tap](flows/proxy-tap.md).

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

The runtime links the system `libnghttp2` for HPACK decoding and encoding and
`libbrotlidec` for captured Brotli bodies. The
default prefix is `/opt/homebrew/opt/libnghttp2` on Apple Silicon,
`/usr/local/opt/libnghttp2` on Intel macOS, and `/usr` elsewhere. Override it
with `zig build -Dnghttp2=/path/to/prefix`. The Brotli defaults use the same
platform prefixes; override them with `zig build -Dbrotli=/path/to/prefix`.
