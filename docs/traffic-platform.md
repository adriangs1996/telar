# Traffic applications on the C++ runtime

Target contract for the requested traffic platform. Packet observation is
documented in [traffic-capture.md](traffic-capture.md); implemented flow events,
transparent TLS and stream hooks are documented in [traffic-flows.md](traffic-flows.md).
HTTP/1 and terminating HTTP/2 message interception are implemented. [Bounded
in-memory recordings](traffic-recordings.md) support cursor queries and PCAPNG
export across Desktop reconnects. [Persistent runtime traffic workers](traffic-workers.md)
support digest-bound observation, interception, recording and administration
grants with live revocation and isolated recording namespaces.
[Runtime administration](traffic-control.md) is implemented with an explicit
account-level grant. On 2026-10-29, the user reported passing native Lua-driven
capture/redirect activation, binary relay, cleanup and restored direct connections.
Repeater workflows belong to client applications.

The [transparent TCP adapter](transparent-redirect.md) selects
local connections by runtime account and numeric destination, with optional
birth-pinned process selection. The administration API resolves exact DNS names
to an activation-time numeric snapshot without privileging DNS resolution.
Process ownership, DNS bounds and numeric authorization pass native tests;
privileged process/domain selection also passed on 2026-10-30. Its root helper
uses a private utun for discovery and exact PF rules for socket handoff to the
C++ runtime. Explicit incoming-only and combined direction selection is also
implemented for active local non-loopback destinations, with a socket-account
check before handoff. Incoming-only and combined IPv4 forwarding passed native
acceptance on 2026-10-30. On 2026-10-27, the user reported passing combined native acceptance
for IPv4/IPv6 loopback and IPv4 LAN forwarding, destination exclusion, concurrent
helpers, crash recovery and cleanup. Native loopback packet capture through
Desktop Lua also passed. Explicitly bound IPv4 LAN sockets on `en0` passed capture
and forwarding on 2026-10-30. VPN and incoming IPv6 remain unverified.

The proxy provides traffic infrastructure for user applications. It does not
derive agent lifecycle state from network activity. Capture, forwarding, TLS
authorities and interception rules belong to the runtime's services. A Desktop
window can close without terminating forwarding or the helper's redirect rules.
A client-owned stream hook resolves its pending decisions according to its
declared disconnect policy.

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
| C++ `proxy/` | Authenticated CONNECT, bounded connections, DNS resolution, forwarding, privileged transparent TCP socket ingress, HTTP/1 and terminating HTTP/2 message editing; incoming-only and combined IPv4 forwarding acceptance passed | Incoming IPv6 and VPN forwarding acceptance |
| C++ `redirect/` | Numeric IPv4/IPv6 TCP selection, optional outgoing process ownership and DNS address snapshots, explicit incoming/both modes for local destinations, private PF activation/recovery, root-owned egress and socket-account-checked handoff; process/domain, incoming/both IPv4, bound IPv4 LAN and helper lifecycle acceptance passed | Incoming IPv6, DNS refresh, VPN/bound remote-IPv6 checks and platform adapters |
| C++ `traffic/` | C++ libpcap helper, interface discovery, private data channel, BPF subscriptions, bounded IPv4/IPv6 fragment and TCP reconstruction, structured UDP/ICMP messages, packet/flow/HTTP delivery, ordered decisions, bounded recording/query and PCAPNG export; native loopback/LAN, bound IPv4 LAN, virtual-interface lifecycle and offline fragment/datagram delivery to Lua passed | VPN capture acceptance and durable archives |
| C++ `tls/` and `proxy/trust/` | CA persistence, leaf minting, origin verification, ALPN, trust installation/removal/rotation, app-facing certificate/status/control, session-safe signer replacement and staged failure events; forced TLS 1.2/1.3, pinning rejection and opaque exclusion fixtures pass; actual Chrome/user-keychain installation, rotation, publication-failure recovery and removal passed | Native fault injection of partial OS trust-command rollback; browsers with private trust stores |
| C++ `exchange_capture/` | HTTP/1 and HTTP/2 capture, byte quotas, decoding and joining; completed exchanges retained through runtime recordings | Cross-source passive/proxy packet correlation |
| C++ `plugins/` | Digest-bound traffic grants with live revocation, isolated persistent Lua workers, subscriptions, ordered inline decisions, package-bound control/recording and bounded crash recovery | Configuration reload and app management from Desktop |
| Desktop `ui/api.lua` | Runtime subscriptions, asynchronous I/O, Lua UI, traffic subscriptions, scoped hooks, runtime capture/redirect and CA administration, recording/query/PCAPNG | Package-bound traffic permissions |
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

Subscriptions are read-only. An app that needs retention can request a bounded
[runtime recording](traffic-recordings.md) and query it by cursor. The user controls its byte
budget and expiry. Neither a packet callback nor the Desktop Lua heap becomes
the unbounded archive. Captures remain scoped to the machine that produced
them; reconnecting clients cannot reuse stale flow or packet identities.

### Stream interception

The implemented [stream API](traffic-flows.md) composes up to 32 explicitly scoped
controllers in registration order, with per-owner decision tickets, bounded
chunks, per-step deadlines and declared failure behavior. It pauses
one connection direction, including other HTTP/2 streams sharing that
direction. It provides raw-byte replacements and reports actually forwarded
bytes. It does not implement HTTP message editing or independent HTTP/2 stream
decisions.

### Message interception

`traffic.intercept({stage = "http", ...}, callback)` implements complete HTTP/1
and HTTP/2 request and response decisions on cleartext or inspected TLS connections. It
uses the same ordered, owner-bound hook composition as stream decisions.
Headers and trailers retain their order and duplicates; bodies are binary and
decoded before delivery. Replacements regenerate Content-Length or chunking
and re-encode gzip, deflate, Brotli and Zstd. See the implemented API and limits
in [traffic-flows.md](traffic-flows.md#http-message-hooks).

`http-message-tests` exercises transport partial writes, unsent message holds,
compression, trailers, Expect/100-continue, HEAD metadata, strict chunk framing
and fail-open/fail-closed limits. `check_traffic_hooks.py --http-edit` exercises
the actual runtime, Desktop Lua, two ordered handlers and a TCP origin with
512 KiB/384 KiB decoded request/response bodies, gzip and trailers.

`http2-endpoint-tests` exercises two nghttp2 endpoints with separate stream and
connection credits, independent interception decisions, ID mapping, partial
writes, PING, reset isolation, cancellation, fail-open/fail-closed deadlines,
streaming pass-through, HEAD method changes, GOAWAY and origin EOF while a
response is waiting. `check_traffic_hooks.py --http2-edit` uses independent
Python h2 peers, the actual runtime and two Desktop Lua hooks. It verifies that
a held stream stays unsent while another stream completes large gzip edits
and trailers, then releases it through a third request. The transparent TLS
fixture additionally verifies message edits through authenticated CA chains
with ALPN h2.

The client application owns rewrite policy, matching rules and any editing UI.
The runtime provides interception points before delivery, bounded pending data
and authenticated decision operations. The remainder of this section states
the full target contract, including background-worker extensions.
It does not add a built-in rewrite-rule language or a repeater.

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

## Acceptance evidence

The delivery scope above remains the completion checklist. Evidence below is
limited to the exercised paths; a prepared verifier is not a passing native run.

| Delivery | Verified evidence | Remaining native acceptance |
| --- | --- | --- |
| 1. Interface observation | Actual PCAP importer, binary/BPF/cancellation delivery to Desktop Lua; user-reported native loopback capture and Lua-controlled helper activation/cleanup; native `en0` LAN capture with outbound/inbound binary payloads, interface attribution and Desktop Lua cancellation; two native virtual-interface creation/packet/removal cycles through Lua with index consistency and cancellation; native IPv4 LAN capture from a socket explicitly bound to `en0` | Controlled VPN capture |
| 2. Reconstruction and ingress | C++ TCP sequence/retransmission/gap, bounded IPv4/IPv6 fragment and structured UDP/ICMP tests; actual fragment/datagram delivery and retained recordings through Lua; user-reported outbound IPv4/IPv6 loopback, IPv4 LAN, exclusions and helper/runtime crash cleanup; Lua `localhost` DNS snapshot activation with native IPv4 binary relay and acknowledged cleanup; native PID-selected IPv4/IPv6 loopback and IPv4 LAN with other processes excluded and cleanup verified; incoming-only and combined IPv4 with authenticated binary relay, half-closes, destination exclusion, expected local-client paths, selected outgoing forwarding and PF restoration; native IPv4 LAN forwarding from a socket explicitly bound to `en0`, including cleanup and restored direct bound connections | Incoming IPv6, controlled VPN forwarding and bound VPN/remote-IPv6 paths |
| 3. TLS and HTTP | Forced TLS 1.2/1.3, both CA chains, rejected origin/client trust, pinning rejection without fallback, opaque exclusion with the original certificate, staged failure events, signer suspension/rotation, same-name/legacy roots and HTTP/1/HTTP/2 plaintext edits; CA export/rotation through actual Desktop Lua; macOS native SSL policy with evaluation-local anchors; actual Chrome rejection of the private CA, user-keychain install/uninstall and installed-CA rotation through Lua, browser HTTPS rewriting, publication-failure suspension and retry recovery, post-removal browser rejection, all three retired authorities rejected and removed, keychain baseline restoration | Native fault injection of partial OS trust-command rollback; browsers with private trust stores |
| 4. Interception decisions | Actual Desktop Lua binary replacements, changed lengths, half-close, HTTP messages and independent HTTP/2 client; C++ framing/compression, stream isolation, ordered owners, deadlines, stale replies and cancellation; persistent workers with crash recovery and live capability revocation | The network paths in rows 1 and 2 remain necessary to extend this evidence beyond the exercised connections |
| 5. Recording and example app | Bounded recording/filter/cursor/loss/export C++ tests; actual recording/query/reconnect and persistent-app namespaces; Lua inspector retention/filter and exact scoped-loss checks; Qt rendering, selection, filtering and loss-footer probe | Broad interface capture acceptance from row 1; durable archives remain outside the implemented in-memory recording contract |

The native acceptance reported on 2026-10-27 predates PID/domain selection,
incoming modes and the routed/interface-lifecycle capture stages. The native Lua
control result reported on 2026-10-29 does not cover those later additions.
On 2026-10-30, the user reported the focused Lua control check with domain
selection passing after the driver-continuation correction: privileged capture
start/stop, a real packet, `localhost` DNS snapshot activation, binary forwarding,
acknowledged cleanup and restored direct connections. The combined verifier
initially stopped at this stage. The next combined run passed actual Lua apps,
recordings, binary/HTTP edits and routed `en0` capture, then stopped at a Lua
verifier assertion rejecting reused interface indices. The corrected lifecycle
verifier then passed in the user-reported focused native check: two virtual
interface creation/packet/removal cycles through Desktop Lua with identity
checks and cancellation. The next focused run passed PID-selected IPv4/IPv6
loopback and IPv4 LAN with process exclusion and cleanup, then timed out during
incoming-only forwarding. After the address-preserving listener/NAT correction,
the user reported incoming-only IPv4 passing: authenticated binary relay,
half-closes, destination exclusion, direct local-client paths and restored direct
connections/PF loopback state after shutdown. The separate `both` run then
passed incoming, selected outgoing and redirected local-client paths, binary
relay, half-closes, destination exclusion and direct/PF loopback restoration.
Current binaries and test adapters target macOS ARM64. Linux forwarding/capture
and Linux cleanup are not implemented or claimed by these results.

On 2026-10-29, the separately authorized browser/keychain check passed for
installation and removal. It verified the retired CA's native trust rejection
and certificate absence before deleting its private fixture. This does not
establish native installed-CA rotation or any additional network-interface path.

On 2026-10-30, the user reported both bound IPv4 LAN stages passing on `en0`:
capture in both directions through Desktop Lua, runtime forwarding with the
original destination, binary relay, exclusion and restored direct bound
connections/PF loopback state after cleanup. The separate
[CA rotation/recovery verifier](traffic-control.md#rotation-and-publication-failure-recovery)
passed its unprivileged preparation and explicitly authorized installed phase
on the same date. Actual Chrome HTTPS rewriting continued after installed-CA
rotation, failed while a second rotation's public certificate publication was
blocked, and resumed after retrying installation of the persisted replacement.
Uninstall rejected and removed all three authorities, restored browser
certificate rejection and the pre-operation keychain certificate baseline, and
removed the private fixture. An independent read-only check confirmed the
baseline and fixture cleanup. This fault occurs after store replacement;
partial OS trust-command rollback is tested with injected commands rather than
native fault injection. A configured VPN peer accepted SSH over its tunnel
route, but refused the temporary echo port; this establishes neither VPN capture
nor forwarding acceptance.

The consolidated native verifier can include the prepared optional stages:

```sh
cmake --build services/runtime-cpp/out --target telar-runtime traffic-interface-probe
sudo -v && /usr/bin/python3 services/runtime-cpp/tools/check_network.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg \
  --ssh-origin YOUR_CONTROLLED_LAN_HOST --selection --incoming \
  --interface-probe services/runtime-cpp/out/traffic-interface-probe
```

Supply the documented VPN host, address and interface options separately when a
controlled VPN destination is available. Omission explicitly leaves VPN coverage
unverified. Browser/keychain acceptance is also separate from this command.
Its [two-phase verifier](traffic-control.md#browser-and-user-keychain-acceptance)
prepares a reviewable certificate before requiring an explicit trust change.
