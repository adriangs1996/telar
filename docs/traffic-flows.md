# Flow events and inline stream hooks

The C++ runtime exposes passive TCP reconstruction, forwarded stream events,
transparent TLS inspection and asynchronous hooks to Desktop Lua. The capture
helper and redirect helper are independent privileged processes. The runtime,
CA keys and Lua callbacks run as the ordinary account.

See [runtime administration](traffic-control.md) for capture/redirect start, stop,
status and public CA export, installation, removal and live rotation from Lua.

## Configuration

```lua
return {
  api_version = 2,
  runtime = {
    proxy = {
      enabled = true,
      network_capture = true,
      transparent_redirect = true,
      transparent_tls = true,
      stream_interception = true,
      intercept_hosts = { "example.com", "*.example.com" },
      capture = { enabled = true },
    },
  },
}
```

`transparent_tls` requires `transparent_redirect`. `stream_interception`
requires both `enabled` and `network_capture`. Each is opt-in. The existing
CA directory and `proxy trust install|status|uninstall` commands apply to both
explicit CONNECT and transparent TLS. Trust configuration and redirect
activation remain separate operations. Applications must trust the CA; the
proxy verifies the origin against its own trusted roots before completing
interception. It does not retry an unsuccessful MITM as an opaque connection.

Start the [capture helper](traffic-capture.md) for interface observation and
the [redirect helper](transparent-redirect.md) for selected TCP destinations.
No helper starts automatically from a Lua subscription. By default, the redirect
adapter selects new connections from the runtime account to numeric IP/port
targets. Explicit `direction = "inbound"` and `"both"` modes additionally select
incoming connections to active local non-loopback destinations and check the
local server's socket account before handoff. Incoming-only and combined IPv4
forwarding passed native acceptance; incoming IPv6 remains unverified. See
[incoming selection](transparent-redirect.md#incoming-selection-and-acceptance-boundary).

Cleartext HTTP/1 and client-first HTTP/2 prefaces use the same forwarding and
capture implementation as inspected TLS. A bounded 8 KiB prefix recognizes the
standard HTTP request methods and preserves fragmented request lines. Unknown
protocols and server-first traffic use the raw relay. An incomplete possible
HTTP prefix falls back to raw forwarding after three seconds. The inspector
uses Host or :authority for its domain filter, with the connection host as a
fallback.

The transparent probe reads ClientHello without consuming it, including hellos
split across TLS records, within 64 KiB and three seconds. SNI selects the
hostname policy and origin verification name. Without SNI the original numeric
address is used. Numeric certificates contain IP SANs for IPv4 and IPv6; exact IPv6 scopes are canonicalized.
Server-first non-TLS protocols can start forwarding as soon as the origin's
banner arrives. ClientHello retry deadlines avoid continuously polling a
partially received hello. Selected ECH and malformed hellos are rejected;
pinning bypass, mTLS, STARTTLS and QUIC interception are not provided. A client
that pins the origin's public key can reject Telar's replacement even when it
trusts Telar's CA. Excluding that host from `intercept_hosts` preserves its
original TLS handshake and certificate; the proxy then observes wire bytes.

## Observe streams

```lua
local stop = require("telar.traffic").subscribe({
  events = { packet = true, flow = true, exchange = true },
  filter = "tcp", -- BPF applies only to packet events.
}, function(err, event)
  if err then print(err); return end
  if event.kind == "stream.data" then
    print(event.flow_id, event.direction, event.offset, #event.bytes)
  elseif event.kind == "flow.gap" or event.kind == "flow.error" then
    print(event.flow_id, event.reason)
  end
end)
```

`flow.open`, `stream.data`, `flow.close`, `flow.error` and `flow.gap` carry
`flow_id`, `client`, `server`, `host`, `direction`, `visibility`, `source`,
`offset`, `reason` and binary `bytes`. IDs, offsets and interception tickets
are decimal strings. Scope a flow by `session_id` and `flow_id`; a new runtime
or capture session has a different session identity. Consumers joining an
existing stream can receive data without its earlier open event. There is no
retained event replay.

`source = "proxy"` identifies a runtime-owned socket connection. Its stream
data reports bytes actually forwarded, after hook replacements. `outbound`
means client to server, and `inbound` means server to client. Each direction
has its own offset. Opaque TLS has `visibility = "wire"`; active TLS streams
have `visibility = "plaintext"`. Ordinary TCP also uses `wire`; this visibility
means that the proxy has not decrypted it. An HTTP exchange uses the same
proxy connection ID as its stream events. HTTP events are bounded observation
copies, not inputs to interception decisions.

TLS failures report their stage through `flow.error.reason`, retained on
`flow.close.reason`:

| Reason | Failed stage |
| --- | --- |
| `tls_client_hello_failed` | Reading the client's TLS offer |
| `tls_origin_handshake_failed` | Connecting TLS to the origin, including origin certificate verification |
| `tls_client_handshake_failed` | Completing TLS with the client, including its rejection of the replacement certificate |
| `tls_certificate_mint_failed` | Issuing or configuring the replacement certificate |
| `tls_context_failed` | Creating the interception/session context |

A client-handshake failure does not identify the client's internal policy; apps
must not label every such event as pinning. Failed interception closes the
connection without changing it into an opaque relay. TLS plaintext is emitted
only after both handshakes complete.

`source = "capture"` identifies a passively reconstructed TCP connection.
Source/interface/session are kept separate, so traffic seen on both physical
and VPN interfaces is not accidentally merged. The SYN sender defines the
client; SYN-ACK identifies the reverse direction. Midstream captures emit a
gap and infer direction from the first observed segment. Retransmitted bytes
are trimmed, out-of-order segments are held, and sequence wraparound is handled.
There is no decryption or modification on this passive path.

The decoder accepts Ethernet with up to two VLAN tags, loopback, raw IP and
Linux cooked link headers. It handles IPv4 options and bounded IPv6 extension
chains. IPv4 and IPv6 fragments are reconstructed before TCP analysis, without
changing the original packet events. A datagram's key includes capture session,
interface name/index, link type, addresses and fragment identity. IPv4 also
includes its protocol. The reconstruction keeps at most 32 datagrams, 128 pieces
per datagram, 65535 fragmentable bytes and 256 prefix bytes. Each pending
datagram reserves 65791 bytes through the runtime's allocator, erased on release.
Unfragmented packets do not allocate fragment storage.

Fragments may arrive out of order. Identical duplicates are ignored; overlaps
with different ranges or bytes abandon the datagram. Rejected identities remain
suppressed until their slot expires or is evicted. IPv6 atomic fragments are
handled independently of queued fragments with the same identity, following
[RFC 8200's fragment processing](https://www.rfc-editor.org/rfc/rfc8200.html#section-4.5).
Incomplete datagrams expire after sixty seconds of runtime time, including
offline imports. Capture shutdown clears their state. Capacity, overlap,
truncation and expiry produce `kind = "error"` with a binary-string reason
beginning `ip_fragment_` and the source capture/interface metadata. This reports
failed analysis, not loss of the original packet. No synthetic assembled packet
is inserted into raw subscriptions or PCAPNG exports. The same stage feeds TCP
analysis and structured UDP/ICMP observations.

TCP reconstruction holds at most
256 flows, 32 queued segments per direction, 64 KiB per flow and 8 MiB overall.
A gap expires after two seconds; idle flows expire after sixty. Queue limits,
ambiguous buffered overlaps, truncation and missing bytes produce explicit
gap/close events. Already emitted retransmissions are not retained for
conflicting-overlap comparison. It is a bounded observation stream, not a
replacement TCP endpoint.

The actual PCAP-to-Desktop Lua check exercises out-of-order IPv4/IPv6 fragments,
byte-exact original packet delivery, provenance, binary TCP reconstruction and
an explicit reconstruction-error event for an invalid fragment:

```sh
python3 services/runtime-cpp/tools/check_traffic.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg --fragments
```

That check and `ip-fragment-tests` pass with normal and AddressSanitizer builds.
It establishes offline import and Lua delivery, not physical/VPN capture coverage.

Subscriber queues still hold eight frames. Drops are cumulative and visible
through the existing counters; a subscriber must not assume a gap-free view.
Passive and proxy flow identities do not claim packet-to-HTTP correlation.

## Observe datagrams

```lua
local stop = require("telar.traffic").subscribe({
  events = {datagram = true},
}, function(err, event)
  if err then print(err); return end
  if event.kind == "datagram" and event.transport == "udp" and event.destination_port == 53 then
    inspect_dns_payload(event.source_address, event.bytes)
  end
end)
```

`kind = "datagram"` observes one UDP, ICMP or ICMPv6 message from passive capture.
It carries `transport = "udp" | "icmp" | "icmpv6"`, `ipv6`, numeric
`source_address`/`destination_address`, capture provenance and binary `bytes`.
UDP events additionally carry numeric `source_port` and `destination_port`;
their bytes contain the UDP payload without its eight-byte header. ICMP events
carry numeric `icmp_type` and `icmp_code`; their bytes contain the complete ICMP
message, including its header. Echo requests/replies with a captured echo header
and code zero also expose `icmp_identifier` and `icmp_sequence`.

`captured_bytes`, `original_bytes` and `truncated` describe that message
representation. An incomplete transport header produces no structured event;
its raw packet remains observable. Checksums are not validated. IPv6
jumbograms are unsupported. Addresses needing a zone retain their capture
interface separately. No client/server role, `direction` or TCP `flow_id` is
invented for a datagram. Applications can group conversations by session,
interface, transport, addresses and ports when applicable.

Datagrams reuse bounded IPv4/IPv6 fragment reconstruction. A completed message
has the completing packet's timestamp and sequence. Subscriptions and runtime
recordings can select `datagram` independently of packet, flow and exchange
events. BPF `filter` still applies only to raw packet events; match structured
ports/protocols in the application's callback. Datagrams do not acquire a DNS
hostname for recording host filters. These observations do not provide UDP or
ICMP rewrite decisions or active forwarding.

The actual importer/runtime/Desktop check verifies all three transports,
fragmented IPv6 messages, original packets, message boundaries, binary data and
structured recording queries:

```sh
python3 services/runtime-cpp/tools/check_traffic.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg --datagrams
```

That check passes with normal and AddressSanitizer runtimes. Native Lua-host
tests cover the same DTO and subscription selection for persistent apps.
`check_traffic_recordings.py` additionally verifies reconstruction and retention
without any connected subscriber, followed by a Desktop reconnect and query.

## Decide before forwarding

```lua
local stop = require("telar.traffic").intercept({
  host = "example.com", -- Required exact hostname, *.suffix, or *.
  direction = "outbound", -- outbound, inbound, both; default both.
  visibility = "plaintext", -- plaintext, wire, both; default plaintext.
  timeout_ms = 1000, -- 1..30000.
  failure = "allow", -- allow original bytes or reject the connection.
}, function(err, event)
  if err then print(err); return end
  if event.kind == "ready" then return end

  -- Returning a decision answers immediately. Alternatively retain
  -- event.respond and invoke it later, within the runtime's deadline.
  return { action = "allow" }
  -- return { action = "replace", bytes = replacement }
  -- return { action = "reject" }
end)
```

The callback receives `intercept.request` with the flow metadata, original
unsent bytes and a unique ticket. `event.respond(decision)` answers once and
returns false after cancellation or a previous local answer. A response queued
to the socket is not an acknowledgement that it beat the runtime deadline.
The runtime ignores late replies and never applies them to another chunk.

Up to 32 controlling subscriptions are accepted per runtime. Matching hooks run
in registration order. Each hook receives the previous hook's replacement,
including an empty replacement. Allow continues the chain and reject closes the
connection. A chunk snapshots its matching registrations, so a newly registered
hook does not join a chunk that is already waiting. Each step has a distinct
ticket bound to its controlling socket; another controller cannot resolve it.
Ordinary observers cannot submit decisions. The private data socket verifies the same-user peer;
`stream_interception = false` rejects controlling subscriptions. A controller's
host, direction and visibility scope is checked before pausing. Host scopes
refer to the connection's SNI or original numeric address, rather than an
HTTP Host header; use the numeric destination or a scoped wildcard for cleartext
HTTP. For cleartext HTTP, visibility is `wire`. Rules apply to
subsequent writes, including existing selected connections. Cancelling the
subscription releases its registration and resolves its steps with the declared
failure policy, preserving earlier replacements when that policy is allow.
Closing Desktop does the same. Registrations from a later connection cannot
inherit an earlier registration's pending steps. These socket identities do not
themselves provide package-bound permissions. [Persistent runtime workers](traffic-workers.md)
use separate native channels, digest-bound grants and retained rules.

There are at most 64 pending chunk chains; replacements are limited to 64 KiB.
Original relay buffers remain bounded and retain their bytes until a decision
and all partial writes complete. Timeout, disconnect and capacity exhaustion
use `failure`. A full controller delivery queue immediately applies that hook's
failure policy rather than dropping the request and waiting for its timeout.
Each step has its own deadline. Only the affected connection direction waits; the proxy worker
keeps processing other connections. Decisions wake the worker through a
completion descriptor rather than a writable-socket polling loop. Rejecting
closes the connection. An empty replacement discards that chunk.

This is a byte-stream hook. Chunk boundaries are not packet, TLS-record, HTTP
message, header, body or WebSocket boundaries. The runtime's TCP sockets handle
changed byte counts; the hook itself does not repair HTTP Content-Length,
chunking, content compression or HTTP/2 HPACK and flow control. Applications
performing protocol edits must preserve those invariants. A paused HTTP/2
connection direction also pauses the other streams on that connection.
Independent HTTP/2 stream decisions and HTTP/1 message editing are available
through the separate API below.
Completed HTTP captures remain
observations of the parser's original messages, while `stream.data` reports
the actual forwarded bytes.

## HTTP message hooks

```lua
local traffic = require("telar.traffic")
local stop = traffic.intercept({
  stage = "http",
  host = "*.example.test",
  failure = "allow",
  timeout_ms = 2000,
}, function(err, event)
  assert(not err, err)
  if event.kind ~= "http.intercept.request" then return end
  local message = event.message
  if message.response then
    return {action = "allow"}
  end
  return {action = "replace", target = "/edited", body = message.body .. "\0suffix"}
end)
```

This stage handles HTTP/1.0, HTTP/1.1 and HTTP/2 on cleartext and inspected TLS
connections. HTTP/2 uses separate client-facing server and origin-facing client
sessions when interception is enabled. The passive path retains its mirrored
observer when interception is disabled. `visibility` defaults to
`both` for HTTP hooks. `direction`, host scopes, cancellation, ordering and
failure policies have the same meaning as stream hooks. Matching handlers are
snapshotted when the complete message is offered, before any of it is forwarded.

`event.message` contains `protocol`, `response`, `response_to_head`, `stream_id`,
`method`, `target`, `scheme`, `authority`, `status`, `reason`, `headers`, `trailers`, `body` and
`body_decoded`. Headers and trailers are ordered arrays of `{name, value}`;
duplicate fields are preserved. Bodies are binary strings, decoded according
to Content-Encoding. `body_decoded` is true. HTTP/1 uses stream ID zero;
request/response order on a connection is preserved. HTTP/2 uses the original
client-facing stream ID for both directions, even when the origin-facing ID
differs because another stream was paused.

Return or submit `{action = "allow"}`, `{action = "reject"}`, or
`{action = "replace", ...}` with any of `method`, `target`, `status`, `reason`,
`headers`, `trailers`, `body`, and HTTP/2 `scheme` and `authority`. Omitted fields retain the previous handler's
values. Replace lists as ordered arrays, including an empty array to remove
them. The runtime repairs Content-Length and chunking, validates field syntax,
and re-encodes the modified body using the resulting Content-Encoding. It
supports gzip, deflate, Brotli, Zstd and chains of up to two content codings.
Transport metadata cannot be changed by a decision.

Limits are 1 MiB of decoded body, 64 KiB of message metadata, 64 pending HTTP
message chains and 32 total controlling subscriptions. Encoded entities have
64 KiB of additional capacity; complete buffered wire data has another 64 KiB
for headers, chunk framing and trailers. Collection lasts at most 30 seconds;
`timeout_ms` applies independently to each handler after collection. Streaming
SSE, unsupported codings and quota failures emit `flow.error` with an `http_`
reason and follow `failure`. Fail-open drains the original buffered prefix and
continues forwarding with backpressure. It never presents a truncated body as
a complete editable message. Invalid HTTP/1 replacements terminate the
connection; invalid HTTP/2 replacements reset the affected stream.
Request Expect/100-continue is answered while collecting and stripped from the
forwarded request. HEAD/bodyless response metadata does not require decoding a
nonexistent entity. Original HTTP capture events and forwarded stream events
retain the representations described above.

HTTP/2 accepts at most 64 concurrent streams and charges each connection to a
16 MiB allocator budget. Its initial receive window admits an entire bounded
entity; connection credits are replenished separately while an intercepted
stream waits. Other streams, PING and SETTINGS keep progressing. A rejection,
timeout or peer reset resolves only that stream. A complete response waiting on
a hook survives origin EOF. Server push is disabled through SETTINGS. HTTP/2
CONNECT tunnels and SSE do not provide complete-body decisions; they use the
declared failure policy and remain observable as streams. Streams without a
matching HTTP hook forward progressively, including entities larger than the
complete-body quota.

Changing HEAD to or from another method preserves each endpoint's framing.
When HTTP/1 must finish a client-facing HEAD response before consuming an
unselected origin body, it sends a header-only response with Connection: close
and marks the interrupted source capture incomplete. HTTP/2 can close that
stream without closing other streams.

## Lua inspector

The example footer keeps reported subscriber, kernel, capture-helper and runtime
publication drops separate. Runtime heartbeats do not erase the last capture
sample, and exchange events do not replace it with an unrelated source session.
Counters remain decimal strings, including values above LuaJIT's exact numeric
range. Clearing HTTP rows preserves known losses; a new capture resets the
capture-specific counters. Loss details use a second footer line and do not
replace a capture error's status message.

The module `traffic_inspector` is a small Desktop app that lists captured HTTP
requests, filters literal domain substrings and shows bounded binary-safe
header/body previews. Open it from a Desktop Lua callback:

```lua
require("telar.workbench").command("view", { module = "traffic_inspector" })
```

Enable HTTP capture and route the selected TLS destinations as above. The app
retains at most 200 entries and 2 MiB of preview data, clips each header/body
preview at 4 KiB, supports pause/clear, reports subscription errors and drops,
and unsubscribes on unmount. History storage and repeater workflows remain
client features. The example does not install trust or change redirection.

## Verification

```sh
cmake --build services/runtime-cpp/out --target telar-runtime traffic-tests traffic-flow-tests http-message-tests http2-endpoint-tests redirect-tests tls-tests
ctest --test-dir services/runtime-cpp/out -R '^(traffic-tests|traffic-flow-tests|http-message-tests|http2-endpoint-tests|redirect-tests|redirect-check-tests|network-check-tests|tls-tests)$' --output-on-failure
cmake --build services/desktop-mode/out/debug --target traffic_dbg
python3 services/runtime-cpp/tools/check_traffic_hooks.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg
python3 services/runtime-cpp/tools/check_traffic_hooks.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg --http-edit
# Use a test Python environment with tools/requirements-network.txt installed.
python3 services/runtime-cpp/tools/check_traffic_hooks.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg --http2-edit
```

The actual runtime/Lua hook check proves scoped registration, binary replacement
with a different length, forwarded offsets, half-close forwarding and
cancellation. C++ tests additionally cover transparent TLS certificate identity,
origin trust rejection, generic non-HTTP TLS, numeric IP SANs, cleartext HTTP,
partial writes, deadlines, wire control messages and TCP sequence reconstruction.
A regression publishes interception events from a 192 KiB worker stack; frame
encoding writes directly to bounded allocator-owned storage.
The transparent TLS fixture also authenticates both private CA chains and
verifies rewritten HTTP request targets and binary response bodies after
decryption and re-encryption. This fixture does not install a root into the OS
or validate browser-specific trust behavior.

TLS session tests constrain both endpoints to TLS 1.2 or TLS 1.3 and assert the
negotiated versions. Transparent-service tests additionally exercise a client
that trusts Telar's CA but pins the origin's public key. The selected connection
must fail with `tls_client_handshake_failed`, no forwarded stream bytes and no
opaque fallback. Excluding the same host must preserve its original certificate,
successful pin verification and wire-only observation while relaying the request
and response. Untrusted origins and a suspended signer must report their own
stages on both error and close events. The pin is checked after ordinary chain
validation using [OpenSSL's verification callback](https://docs.openssl.org/3.5/man3/SSL_CTX_set_verify/).

Origin trust keeps distinct certificates even when their subject names match;
only the same certificate is deduplicated. New CAs include a subject key
identifier, and minted leaves identify their signing authority. Existing
authorities without a key identifier use issuer-name/serial information when
minting a leaf. The implementation uses [certificate comparison](https://docs.openssl.org/3.5/man3/X509_cmp/)
and [authority key identifiers](https://docs.openssl.org/3.5/man5/x509v3_config/#authority-key-identifier).
The trust regression verifies leaves from same-name roots, rejects an
unauthorized same-name signer and checks a legacy root without a key identifier.
The same suite also evaluates generated chains through macOS's native SSL policy
with explicit anchors limited to that evaluation and certificate fetching
disabled. DNS and IPv6 identities succeed; a wrong hostname, expired leaf and
empty anchor set fail. This validates native chain compatibility without adding
anything to a keychain. Separate [browser/keychain acceptance](traffic-control.md#rotation-and-publication-failure-recovery)
passed actual Chrome HTTPS rewriting, installation, rotation, publication-failure
recovery and removal on 2026-10-30.

For native capture to Lua, loopback/LAN redirect and concurrent/crashed helper
recovery, run from an interactive terminal:

```sh
python3 services/runtime-cpp/tools/check_network.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg \
  --ssh-origin CONTROLLED_HOST
```

The SSH check starts a temporary authenticated echo server and removes it when
the connection closes. `--ssh-address IP` selects its destination address, and
`--vpn-ssh-origin HOST --vpn-address IP --vpn-interface IFACE` adds a VPN
check and verifies that the destination routes through the declared interface. No destination is
hardcoded. Some macOS Python installations lack local-network access; a native
`No route to host` error can differ by interpreter. Use an interpreter permitted
to access the chosen LAN, such as `/usr/bin/python3` on the tested machine.

Add `--selection` to check native process selection and Lua activation through a
DNS address snapshot. Add `--incoming` with `--ssh-origin` to check incoming-only
and combined redirection: the controlled host also runs a temporary authenticated
client against selected and excluded local destinations. Native process/domain
selection and incoming-only/combined IPv4 checks passed on 2026-10-30.
The routed capture stage also checks packets in both directions on the actual
LAN/VPN interface; the earlier loopback capture result does not establish that
new stage's coverage.
`--interface-probe services/runtime-cpp/out/traffic-interface-probe` adds the
[temporary virtual-interface check](traffic-capture.md#check-delivery-without-root).
Its native creation, binary packet delivery, removal and recreation checks
passed through Desktop Lua on 2026-10-30.

Run the Lua check with `--http` to verify fragmented cleartext HTTP requests and
binary response bodies. The inspector's real Qt rendering, request selection
and domain input are checked by `traffic_inspector_dbg`; its ring retention and
literal domain filters are checked by `luajit tests/traffic_inspector.lua` from
`services/desktop-mode`.

Native loopback redirect first passed on 2026-10-25. On 2026-10-27, the user
reported a successful combined `check_network.py` run on macOS with a controlled
LAN SSH origin. That run verified:

- Real PCAP delivery to Desktop Lua, scoped byte-replacement hooks with length
  changes, stream offsets, half-closes and cancellation.
- Cleartext HTTP delivery to Lua with a fragmented request line and binary
  response body.
- Native UDP capture on `lo0`, including interface provenance and delivery
  through the actual Desktop Lua subscription.
- Native IPv4/IPv6 loopback and IPv4 LAN TCP redirection, original destinations,
  binary relay, destination exclusion and direct connections after cleanup.
- Concurrent helpers, exclusive endpoint ownership, helper crash recovery,
  runtime crash cleanup, the surviving helper's lease and final PF loopback
  restoration.

The run explicitly skipped VPN acceptance because no controlled VPN destination
was supplied. Physical/VPN packet capture, interface changes, interface-bound
applications and incoming-flow redirection are not established by this result.
Transparent TLS certificate/trust cases remain covered by the focused C++ tests;
the combined native check does not perform a browser/system-trust TLS test.

Network checkers use private directories under `/tmp` so macOS's long default
temporary path cannot overflow the auxiliary Unix socket names. A regression
starts the real runtime and completes its traffic subscription with a long
`TMPDIR`, stopping before the privileged helper is launched.

Protocol parsing follows [TLS ClientHello framing](https://www.rfc-editor.org/rfc/rfc8446.html#section-4.1.2)
and [TCP sequence numbering](https://www.rfc-editor.org/rfc/rfc9293.html#section-3.4).
