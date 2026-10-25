# Traffic applications on the C++ runtime

Target contract for the requested traffic platform. The initial observation
API is documented in [traffic-capture.md](traffic-capture.md). The broader
flow and interception APIs below remain proposals. Repeater workflows belong
to client applications.

The proxy provides traffic infrastructure for user applications. It does not
derive agent lifecycle state from network activity. Capture, forwarding, TLS
authorities and interception rules belong to the runtime's services. A Desktop
window can close without terminating forwarding or installed runtime rules.

## Coverage

Observe the machine's physical, loopback and virtual network interfaces,
including LAN, inbound and VPN traffic visible to the OS capture facility.
Discover interfaces that appear after activation and report interfaces that
cannot be opened. The user selects which flows to intercept separately.

Observation is best effort, with explicit kernel, service and subscriber loss
counters. "All interfaces" describes the requested scope; it does not promise
lossless capture at arbitrary link rates. Unsupported packets retain their
original bytes and link type rather than disappearing.

A VPN can expose both its outer encrypted packets and inner packets on a
virtual interface. Preserve each observation's interface and layer. Do not
silently merge them or promise access to traffic inside a tunnel whose clear
side is unavailable to the OS. Likewise, loopback observations must not be
mistaken for two independent exchanges.

The Go prototype's `-all` mode is a reference for active forwarding, not a
complete interface capture backend. It redirects default-routed IPv4/IPv6
through TUN and preserves more-specific LAN, loopback and VPN routes. See
[the prototype's current behavior](proxy-service.md#current-ipv4-and-ipv6-prototype).

## Existing components

| Component | Reuse | Missing for this contract |
| --- | --- | --- |
| C++ `proxy/` | Authenticated CONNECT, bounded connections, DNS resolution, forwarding | Transparent flow ingress, plain HTTP capture |
| C++ `traffic/` | C++ libpcap helper, interface discovery, private data channel, BPF subscriptions, bounded packet and HTTP exchange delivery | Privileged native capture acceptance, flow reconstruction, interception and retention |
| C++ `tls/` and `proxy/trust/` | CA persistence, leaf minting, origin verification, ALPN, trust installation/removal and rotation | An app-facing status/control contract for these operations |
| C++ `exchange_capture/` | HTTP/1 and HTTP/2 capture, byte quotas, decoding and joining | Generic flow events and retained queries |
| C++ `plugins/` | Digest-bound grants, isolated Lua workers, bounded queues and deadlines, `on_exchange` | Packet/flow subscriptions, app delivery and inline interception decisions |
| Desktop `ui/api.lua` | Runtime subscriptions, asynchronous I/O, Lua UI and traffic subscriptions | Traffic recording/query and inline-rule management |
| Go `services/proxy/` | macOS/Linux TUN adapters, TCP netstack, IPv4/IPv6 forwarding and TLS detection | Telar IPC, full interface observation and interception decisions |

These paths are independent of the agent tracker. Existing tap callbacks
receive completed captured exchanges and return notification effects; they
cannot change bytes that have already reached the peer.

## Three observation levels

| Level | Required data | Meaning |
| --- | --- | --- |
| Packet | Capture session and sequence, timestamp and precision, interface identity, link type, captured/original length, original bytes, truncation and loss information | One observation at a capture point. It is not an application message. |
| Flow | Runtime flow identity, capture provenance, source/destination and transport, direction, stream offset, lifecycle and gaps | A connection or datagram conversation. TCP bytes require bounded reassembly; retransmission does not create new stream bytes. |
| Exchange | Flow identity, protocol, stream/exchange identity, ordered header fields and bodies, timing, completion, decoding and truncation | A protocol message or request/response pair, including HTTP/2 multiplexing. |

Packets and stream reads have different boundaries. A `stream.data` callback
must expose its direction and byte offset without claiming one callback equals
one TCP packet, TLS record, HTTP request or WebSocket message. Datagram events
preserve message boundaries. Fragmented IP packets require bounded fragment
handling before transport decoding; incomplete captures remain observable.

Keep network direction, client/server role and request/response direction
separate. For an inbound connection, the local process can be the server.
Preserve IPv6 scope and interface identity where an address requires them.

Each flow states whether it is only observed or actually intercepted. Report
TLS and visibility separately: `cleartext`, `tls_opaque` or `tls_plaintext`,
with an explicit reason when plaintext is unavailable. Do not infer successful
decryption from a configured host rule or an installed root.

## TLS

Passive packet capture plus a CA does not reveal existing TLS plaintext.
TLS 1.3 provides confidentiality against network observers and forward secrecy
for public-key exchanges. See [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446).
Passive decryption needs connection secrets, such as a cooperating endpoint's
key log. See [Wireshark's decryption requirements](https://wiki.wireshark.org/TLS/).

For active TLS inspection, route the selected connection through Telar, verify
the origin before presenting a replacement certificate, and require the client
to trust Telar's CA. Reuse the C++ authority and trust implementation. Never
publish the CA private key or session secrets through an ordinary subscription.

CA creation, installation, verification, removal and rotation are separate
operations with readable status. Expose the certificate and its fingerprint
for applications using private trust stores. An OS installation does not
promise that every application trusts it. Incoming TLS can be inspected only
when the relevant endpoints can cooperate with the interception configuration.

Certificate pinning, client certificates, ECH, STARTTLS and unsupported ALPN
must each have a documented policy and an observable outcome. Observe opaque
bytes when inspection is unavailable. Once a MITM handshake starts, a failure
cannot be treated as if the original connection were still untouched.

QUIC uses UDP; it needs its own interception implementation. Initial TCP/TLS
support must report QUIC as opaque rather than silently blocking UDP/443 to
force a TCP fallback. Decrypted bytes and decompressed HTTP bodies also remain
distinct representations; retain encoding and truncation metadata.

## Application contract

The following Lua illustrates the intended API shape only:

```lua
local unsubscribe = telar.traffic.subscribe({
  events = { packet = true, ["flow.open"] = true, ["stream.data"] = true, exchange = true, ["flow.close"] = true },
  filter = { protocols = { "tcp", "udp", "icmp", "icmpv6" } },
}, function(event)
  -- Binary strings and bounded metadata, suitable for an application view.
  append_to_view(event)
end)

unsubscribe()
```

Subscriptions return independent handles and accept a native filter before
copying bytes into Lua or IPC. Keep packet capture filters and semantic
exchange filters distinct. Do not claim Wireshark display-filter syntax unless
that language is actually implemented. Each subscription has event and byte
limits, sequence numbers, dropped counts and cancellation. A slow app cannot
stall another app or the transport.

Subscriptions are read-only. An app that needs retention requests a bounded
runtime recording session and queries it by cursor. The user controls its byte
budget and expiry. Neither a packet callback nor the Desktop Lua heap becomes
the unbounded archive. Captures remain scoped to the machine that produced
them; reconnecting clients cannot reuse stale flow or packet identities.

### Interception proposal

The client application owns rewrite policy, matching rules and any editing UI.
The runtime provides interception points before delivery, bounded pending data
and authenticated decision operations. This is a proposed contract, not an
implemented API. It does not add a built-in rewrite-rule language or a repeater.

An application registers its selected flows and interception stage. The runtime
holds the affected unsent message or stream portion and delivers an interception
identity to its owner. That client can forward the original, replace selected
content or reject delivery. Ordinary capture subscriptions remain read-only
and cannot resolve interceptions.

Decisions travel asynchronously. Waiting for a client pauses only the affected
flow or HTTP/2 stream through bounded backpressure, not the runtime event loop.
HTTP/2 connection-control frames and other streams must keep progressing.
Pending bytes, output bytes, active decisions and waiting time have limits.
The registration declares what happens on timeout, owner disconnect or a
buffer limit. A reply after expiry is rejected. An isolated runtime worker can
host an application's automatic handler when it must survive Desktop closure;
a connected client can own interactive decisions through the same contract.

Only bytes not yet committed to the peer are eligible for replacement. A
whole-body HTTP rewrite must be selected before forwarding headers and buffer
the complete body within its configured limit. The truncated copies published
for observation are never accepted as complete interception inputs. Streaming
transformations need a separate explicit contract for chunks and completion;
chunk boundaries are not application-message boundaries.

Rules execute at a declared level. Packet modification requires checksum and
fragment handling; changing a TCP payload's length also requires sequence and
acknowledgement translation. Prefer stream/protocol interception for payload
rewrites. HTTP transformations must respect framing, Content-Length, chunking,
compression, HTTP/2 flow control and end-of-stream semantics. HTTP/2 modifications
need a terminating protocol endpoint, not edits to a mirrored HPACK decoder.
The runtime handles these protocol mechanics; applications choose the desired
headers or payload. TLS traffic is transformed after decryption and before
encryption towards the other endpoint.

Multiple apps must not compete for one pending decision. Define handler order
and terminal decisions, include the matching handler identities in audit events,
and reject replies for an expired decision, an old rule generation or a closed
flow. Installing a new rule does not retroactively acquire existing connections.

Repeater history, editing, execution and result comparison belong to client
applications. The proxy supplies reusable traffic and connection infrastructure;
it has no dedicated repeater or replay operation. Generic connection operations
can carry an application identity so interception clients can avoid matching
their own generated traffic recursively.

## Native integration

Use the OS capture facility through libpcap for observation, preserving the
actual link type and per-interface metadata. Enumerating capture devices and
capturing from an `any` device are OS-dependent; an aggregate device alone is
not evidence of interface attribution or coverage. See the
[libpcap device contract](https://github.com/the-tcpdump-group/libpcap/blob/master/pcap_findalldevs.3pcap).

Keep privileged capture/redirection setup in a narrow native helper. The
runtime, Desktop and Lua workers run as the user's account. Authenticate local
peers, validate all frame lengths and keep the capture data channel separate
from control replies. Do not turn the entire runtime into a root process.

The active adapter receives selected flows with their original destination and
returns them through an egress path that cannot recapture itself. Preserve
unrelated routes, firewall rules and connections. Publish changes in interface
availability and adapter health. An unavailable helper leaves existing terminal
work usable and exposes why traffic features are unavailable.

Activation owns its OS changes and cleanup. Test partial startup rollback,
orderly shutdown, helper death and stale-state recovery after a crash. Never
install global routing, root trust or firewall changes just because a window
or runtime starts. Capture authorization, active redirection and CA trust are
separate user choices.

## Delivery and acceptance

1. Interface observation through the C++ runtime to a Lua consumer. Test physical
   interface fixtures, loopback, inbound/outbound traffic, interface additions,
   permissions, cancellation, opaque protocols, truncation and slow subscribers.
   Verify bytes and source-interface attribution, not just event counts.
2. Flow reconstruction and transparent ingress. Exercise IPv4/IPv6, TCP
   retransmission/reordering/overlap, fragments, UDP and ICMP, server-first
   protocols, half-closes, VPN observations and recursion exclusion. Prove
   actual coverage instead of equating default-route redirection with it.
3. Selected TLS interception and HTTP delivery. Use temporary origin and
   inspection CAs, verify TLS 1.2/1.3 and HTTP/1/HTTP/2, and cover rejected trust,
   pinning, opaque exclusions, origin failures and Desktop disconnects.
4. Client-controlled interception decisions. Prove modified bytes reach the peer
   exactly once, including changed lengths, binary payloads, compression and
   concurrent HTTP/2 streams. Test worker timeout/crash, conflicting rules,
   stale replies, cancellation, owner disconnect and application attribution.
5. Bounded recording/query and an example Lua traffic app. Verify filtering,
   cursor expiry, loss indicators, reconnect and shutdown. Run native capture
   and cleanup acceptance separately on macOS and Linux before claiming both.

Each delivery needs executable integration evidence and documented capability
status. Type definitions, mock events and a happy-path callback alone do not
establish capture or interception support.
