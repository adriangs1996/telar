# Go proxy service migration

The new traffic platform is being built in C++, with Go retained only as a
reference. See [the current C++ observation API](traffic-capture.md) and
[its target contract](traffic-platform.md). The Go migration plan below is
historical; its prototype notes still describe the Go executable.

Implementation plan, not an installed feature. The current proxy remains
documented in [ProxyTLS](proxy-tls.md). The architectural decision is recorded
in [ADR 0001](adr/0001-independent-go-proxy-service.md).

macOS and Linux are both targets from the first delivery. Build and validate the
shared Go service and Zig IPC consumer on both; validate both native adapters
during the second delivery before proceeding to the complete inspection migration.

## Current IPv4 and IPv6 prototype

`services/proxy/cmd/telar-proxy` captures one unicast destination with
`-route <IP>` or default-routed IPv4 and IPv6 traffic with `-all`. These modes
are mutually exclusive and activation must be explicitly requested. In `-all`,
a family without a default route is left inactive; other discovery errors abort
startup. IPv4 and IPv6 can use different outbound interfaces. There must be at
least one usable default route.

From the repository root:

```sh
go -C services/proxy build -o ../../.zig-out/dev/bin/telar-proxy ./cmd/telar-proxy
sudo .zig-out/dev/bin/telar-proxy -all
```

Check both families in another terminal:

```sh
ping -c 3 1.1.1.1
# macOS
ping6 -c 3 2606:4700:4700::1111
# Linux
ping -6 -c 3 2606:4700:4700::1111
```

Use `-route 1.1.1.1` or `-route 2606:4700:4700::1111` to capture only that
destination and family. TUN addresses default to `192.0.2.1` / `192.0.2.2` and
`fd7a:115c:a1e0:7465::1` / `fd7a:115c:a1e0:7465::2`. Override them with
`-tun-address`, `-tun-peer`, `-tun-address6` and `-tun-peer6` if they conflict.
Startup rejects already assigned addresses and invalid or mixed-family pairs.
The kernel selects the original interface's IPv6 source through a bound UDP
socket connection that transmits no packet.

`-all` installs `0.0.0.0/1` and `128.0.0.0/1` for IPv4, and `::/1` and
`8000::/1` for IPv6. Original default routes are preserved. More-specific routes,
including connected LAN, loopback and existing VPN routes, retain their priority.
Link-local and multicast IPv6 control packets read from the TUN are not relayed
to the uplink. Capture is voluntary: on macOS, `ping -S` and `ping6 -S` with a
physical source address can bypass it. On Linux, explicitly binding the physical
interface, for example with `ping -I <interface>`, provides the intentional
bypass. Binding only an address has OS-dependent behavior.

TCP packets are dispatched to gVisor netstack, which owns the application's
TCP handshake, acknowledgements, retransmissions and stream assembly. Its
virtual NIC accepts original destinations and responds using their addresses.
A Go TCP socket bound to the original interface connects to each destination;
the handler relays bytes both ways and preserves half-closes. IPv4 and IPv6
select their outbound interfaces independently. TLS is opaque by default.
Explicit host rules and an existing signing authority enable TLS inspection
as described below. Telar IPC is still pending.

The adapter owns packet bytes copied from the reusable TUN read buffers. Its
outbound channel is bounded to 256 packets, and it admits at most 256 concurrent
TCP connections, including pending handshakes. Shutdown cancels dials and
relays, aborts incomplete handshakes, and joins callbacks and stack workers.
IPv4 and IPv6 TCP fragments are processed by netstack. IPv6 hop-by-hop,
routing, destination options and gVisor's experiment header are recognized,
including chains after the fragment header. The first fragment supplies the
transport protocol for the datagram. If later fragments arrive first, a bounded
dispatcher holds copies until the first arrives, then delivers the original
packets unchanged to the TCP adapter or native sender. This uses the first
fragment's complete header chain described in [RFC 8200](https://datatracker.ietf.org/doc/html/rfc8200#section-4.5).
It does not reassemble IP packets. Decisions use both IPv6 addresses and the fragment ID, expire after
60 seconds and are capped at 1024 datagrams. Pending packet data is limited to
4 MiB and 64 fragments per datagram. Expiry is checked on fragment arrival.
Conflicting fragment protocols are rejected; atomic fragments are dispatched
independently without affecting a pending datagram with the same ID, as required
by [RFC 6946](https://www.rfc-editor.org/rfc/rfc6946.html#section-4).

Other IPv4 packets use a raw socket bound to the original interface. Linux IPv6 uses
a bound raw socket with `IPV6_HDRINCL` and sends complete packets, keeping
extension headers and transport bytes opaque. macOS does not provide the same
IPv6 raw-header interface, so IPv6 uses a second, private egress TUN. Go writes
the complete packet to that TUN; a PF `route-to` rule delivers it through the
original interface and gateway. The egress TUN has a scoped link-local IPv6
address to enable IPv6 input, and its generated control traffic is drained.
Private PF scrub rules reassemble IPv6 fragments before NAT and let the kernel
refragment them for transmission. The PF route-to gateway retains its interface
zone, including for the refragmented path. Neither native sender enables global
IP forwarding. IPv6 jumbograms are unsupported; ordinary non-TCP IPv6 fragments
are forwarded.

macOS uses one private PF anchor per active family under `com.apple/*` and
acquires an enable reference with `pfctl -E` for each. The main ruleset must
already expose `nat-anchor "com.apple/*"`, `anchor "com.apple/*"` and
`scrub-anchor "com.apple/*"`; startup fails if a hook is missing without replacing system rules. NAT/NAT66 translates
the TUN source to the original interface's source. Rules prevent state creation
on the initial TUN pass, tag translated packets, and bind their states to the
outbound interface. Only tagged flows use `reply-to`, so direct traffic retains
its return path. PF sends reverse-translated replies into the capture TUN;
Go writes them back unchanged to deliver them on the interface owning their
address. It does not change the global interface address checks.

For `-all` on macOS, matching `/1` routes scoped to each original interface and
gateway keep outbound traffic from being recaptured. Cleanup checks route
ownership before deleting a route, removes private rules and captured states,
and releases only the acquired PF references.

Linux requires `ip`, `nft`, `conntrack` and `sysctl`. Each active family owns a
private nftables table. The initial TUN pass bypasses connection tracking;
SNAT/NAT66 applies when the raw sender emits through the original interface.
The capture route prefers the TUN source. The kernel translates returning
packets back and delivers them to the application's original socket. If strict
IPv4 reverse-path validation would reject replies, the service temporarily sets
loose validation on the outbound interface and restores its prior value,
provided another process has not changed it. IPv6 does not alter that setting.

SIGINT, SIGTERM and partial activation failures trigger cleanup. A failure while
activating IPv6 unwinds IPv4 as well. Losing a piped log consumer does not kill
the service through SIGPIPE before cleanup. This prototype does not recover
persistent firewall state after SIGKILL, follow network changes or inspect TLS.
Existing connections using the temporary TUN addresses can disconnect on shutdown.

Run Linux tests in Docker:

```sh
just proxy-test-linux
```

The test builds binaries for the Docker engine's architecture, runs unit tests
and starts two containers in a temporary internal network with IPv4 and IPv6.
It verifies ICMP, UDP and TCP, source translation, IPv6 fragmentation, simultaneous
dual-stack capture, activation on IPv6-only networks, interface-bound bypass, SIGTERM/SIGINT cleanup, repeated
activation, and preservation of unrelated rules, connections and default routes.
Startup failure tests preserve pre-existing routes and unwind both families.
A closed log pipe test verifies that forwarding continues and shutdown cleans up.
TCP checks require evidence that the socket handler ran, relay 2 MiB in each
direction after a client half-close, exercise concurrent connections and a
refused origin port, and stop the service with an idle connection and an
incomplete TCP handshake. Unit
tests also check opaque TLS with certificate verification and cancellation.
IPv6 tests send real TCP, UDP and ICMPv6 packets with options before and after
the fragment header, in both arrival orders, and verify atomic-fragment TCP
handshakes. Unit tests check queued buffer ownership, expiry, memory limits,
address isolation and rejection of conflicting protocol decisions.
Containers and the network are removed after the test; the cached image remains.

## TLS inspection prototype

Load the certificate and key of an existing Telar authority. The service does
not create an authority, overwrite CA files or install OS trust. Applications
must trust the selected authority; for a controlled test, curl's `--cacert`
selects it without changing system trust.

```sh
sudo .zig-out/dev/bin/telar-proxy -all \
  -inspect-host api.example.com \
  -tls-ca-cert /path/to/ca-cert.pem \
  -tls-ca-key /path/to/ca-key.pem

curl --noproxy '*' --cacert /path/to/ca-cert.pem https://api.example.com/
```

Repeat `-inspect-host` for additional rules. `*.example.com` matches proper
subdomains; `*` explicitly selects all visible hostnames and IP destinations.
Quote wildcards to keep the shell from expanding them. Missing rules leave
TLS inspection disabled. `-tls-upstream-ca /path/to/roots.pem` optionally adds
private origin roots to system roots. It does not disable certificate or
hostname validation. Invalid configuration fails before network activation.
Telar's private files are `ca-cert.pem` and `ca-key.pem` under its configured
`ca_dir`; the system-trust pair uses `ca-system-cert.pem` and
`ca-system-key.pem`. Select the pair the application trusts.

The handler detects direct TLS independently of the destination port. It uses
Go's bounded ClientHello parser to read SNI and ALPN, preserving consumed bytes
for replay. A concurrent peek of the origin preserves server-first protocols.
The initial peek waits at most ten seconds; TLS setup has a thirty-second
budget. Certificate files must be regular and not writable by other accounts;
keys must have mode 0600 or stricter. Symlink files and files larger than 64 KiB are
rejected. Leaves are cached for at most 256 hosts and expire within 24 hours
or the signing authority's validity period, whichever comes first.

For selected hosts, the origin handshake is verified before minting a leaf or
starting the application's TLS handshake. The origin receives the client's
HTTP ALPN offer, and only its selected protocol is advertised downstream.
TLS 1.2 and 1.3 provide decrypted streams for HTTP/1.1 and HTTP/2. Streams are
relayed unchanged with half-close handling. `TLSInspector.observe` receives
borrowed plaintext buffers in both directions; a consumer must copy bytes it
retains and support concurrent callbacks. The CLI logs host, ALPN and plaintext
byte counts, without logging headers, bodies or keys. Structured HTTP exchange
capture, modification policy and delivery to Telar remain subsequent steps.

Excluded hosts, non-HTTP ALPN offers and ECH-bearing ClientHellos pass through
with their original TLS identity. ECH hides the inner hostname, so this stage
does not inspect it. QUIC remains on the UDP forwarding path. Selected hosts
fail closed on origin validation or downstream TLS errors; a client that pins
the origin certificate or does not trust the inspection authority may reject
the replacement certificate. TLS upgraded within an already relayed plaintext
protocol, such as STARTTLS, is outside this initial detector.

Docker TLS tests use separate ephemeral origin and inspection authorities and
verify HTTPS inspection over IPv4 and IPv6, original certificates outside the
selected scope, wildcard scope, no-SNI IP certificates, ALPN and cleanup. Unit
tests verify TLS 1.2/1.3 plaintext in both directions, an actual HTTP/2 exchange,
untrusted or incorrectly named origins, ECH passthrough, server-first traffic,
half-closes and cancellation. Test authorities never enter an OS trust store.

## Ownership

| Component | Owns |
| --- | --- |
| Proxy service in Go | Proxy policy, connection lifecycle, TLS authorities, bounded capture, proxy status and metrics |
| Native network adapter | OS-authorized redirection, original destination metadata, adapter health and removal of its own redirection |
| Terminal runtime in Zig | Panes, agents, history and authorized plugin consumers of captures |
| Telar GUI and CLI | User control and presentation of the selected machine's proxy state |

The service ships with Telar and survives client-window closure. A runtime
restart does not stop it. Process availability, proxy activation, TLS
interception scope, capture enablement and installed CA trust are separate facts.
The ordinary Go service runs with user permissions; platform authorization is
restricted to the network integration that needs it.

Application bytes go through the adapter and Go relay. An adapter in another
process may need a local data channel to Go. The Go-to-Zig connection carries
control, status and subscribed captures, with independent delivery for captures
so a slow consumer cannot block control or relay work.

Each machine owns its activation and configuration. Multiple Telar runtimes on
the same account must address the same production service rather than compete
to install redirection. Development and test instances use separate endpoints
and never acquire production redirection implicitly. The adapter spike must
establish the supported multi-user scope before system-wide coverage is claimed.

## First delivery: process and IPC

Create a Go module under `services/proxy/`, with an internal `telar-proxy`
executable. It starts in an inactive state. Implement process availability,
status and orderly shutdown first; activation reports unsupported until a
working adapter exists. The internal executable is an implementation component,
while the public commands belong to `telar proxy`.

Use a filesystem Unix socket for macOS and Linux. Reuse
[`lib/localsocket`](../lib/localsocket/root.zig) on the Zig side, including its
peer checks and protected directory conventions. Go must enforce equivalent
directory ownership, same-user peer authentication, socket lifetime and
duplicate-start behavior. Privileged adapter communication has its own
authorization boundary.

For the initial control contract:

- A four-byte little-endian length prefix follows the existing
  [transport framing](../lib/localsocket/transport.zig); control payloads use
  JSON with a named 64 KiB limit, checked before allocation.
- The initial handshake negotiates a proxy-specific protocol version.
  Incompatible versions close with a useful error before accepting commands.
- Requests have an ID and an operation; responses carry that ID, a result or a
  stable error code. The first operations are `status` and internal `shutdown`.
- Status distinguishes service availability, activation transition, adapter
  capability and health, interception policy, capture enablement and CA trust.
- Bound active clients, idle reads, pending writes and shutdown time. A
  disconnected controller leaves the service running.

Add the Zig consumer using the existing socket layer, rather than porting the
whole runtime protocol to Go. Keep the proxy control schema independent of pane
messages. Capture framing will be specified when the relay can publish captures;
body bytes should be binary and bounded, rather than base64 control fields.

Completion: a Telar-controlled service answers status, rejects incompatible
versions and unauthorized peers, survives the client disconnecting, and shuts
down cleanly without touching panes or machine networking. Go and Zig exchange
the same protocol fixtures, including fragmented and oversized frames. Exercise
concurrent startup and a stale socket without unlinking a live listener.

## Second delivery: prove native redirection

Before migrating the complete TLS engine, validate an adapter with an opaque
relay from an application started outside Telar, without proxy environment
variables. Start with TCP and record the exact supported coverage. TCP-only
success is a milestone, not completion of machine-wide proxying.

On macOS, investigate
[`NETransparentProxyProvider`](https://developer.apple.com/documentation/networkextension/netransparentproxyprovider)
and the
[Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension).
Prove activation, signing and provisioning, native-to-Go flow delivery, original
destination recovery and exclusion of the relay's own outbound connections.
Validate the distribution path for ordinary users as part of this spike.

On Linux, evaluate
[TUN](https://docs.kernel.org/networking/tuntap.html) against
[transparent proxying and policy routing](https://docs.kernel.org/networking/tproxy.html)
for locally originated traffic. A router PREROUTING example is not by itself a
solution for traffic generated on the same PC. Establish privilege separation,
IPv4 and IPv6 coverage, destination recovery and coexistence with existing rules.
If TUN is selected, choose an existing packet/stream implementation rather than
writing a TCP stack for this project.

Activation is ordered: make the relay ready, install redirection, verify the
adapter, then publish active status. Roll back partial activation. Deactivation
first withdraws redirection for new connections and then settles existing
proxied flows within a documented deadline. Disabling the proxy and terminating
its service are distinct operations.

Proposed failure policy: restore direct networking when the service fails,
because this is an inspection feature. The platform adapter or supervisor must
implement recovery; cleanup in the Go process cannot run after it is killed.
Accepted redirected flows may still disconnect. Test this policy explicitly
before making it part of the user contract.

Completion on both macOS and Linux: an external application's TCP traffic reaches
the Go relay, own outbound traffic bypasses recapture, off restores direct
connections, and forced service termination recovers networking. Demonstrate
IPv4/IPv6, repeated activation, two clients controlling the same service and
restart recovery. Document existing-flow behavior and multi-user scope.

## Third delivery: migrate inspection and capture

Use the existing Zig proxy as the behavioral reference:

- [Tunnel establishment](../src/backend/proxy/tunnel/Tunnel.zig) and
  [TLS negotiation](../src/backend/proxy/tunnel/Establisher.zig).
- [Interception policy](../src/backend/proxy/Policy.zig), exact and wildcard hosts.
- [`httprelay`](../lib/httprelay) and the HTTP/1.1 and HTTP/2 observation paths.
- [Capture limits](proxy-tls.md#exchange-capture) and the existing plugin
  [exchange protocol](../src/backend/plugins/protocol.zig).
- [Explicit pane environment](../src/backend/proxy/proxy_namespace.zig) and
  existing secret, port and authority compatibility.

Specify hostname attribution for redirected IP connections, including missing
SNI and encrypted ClientHello, before applying hostname interception rules.
Unknown destinations stay opaque unless an explicit supported policy says
otherwise. Installing a system CA remains an explicit operation independent of
activation. Application trust stores and certificate pinning remain inspection
constraints.

Keep wire relay and capture parsing separate. Evaluate Go libraries against
byte-preserving forwarding, ALPN, concurrent request/response streaming,
HTTP/1.1 informational responses, HTTP/2 flow control and half-close behavior;
HTTP message reserialization must not silently replace the existing contract.
Retain bounded queues, memory accounting and truncation outcomes. Deliver captures
only to runtime consumers with authorized tap plugins. State observations alone
do not grant access to bodies.

Define which runtime receives machine-wide captures. Traffic from outside Telar
has no pane identity, and an account's multiple runtimes must not accidentally
duplicate or persist every capture. Reconcile capture enablement and plugin
authorization before subscribing.

Completion: paired integration cases compare relay behavior and capture outputs
with Zig, including large and streaming bodies, HTTP/2 multiplexing, malformed
inputs, timeout, disconnection and capture saturation. Compare latency percentiles,
CPU and RSS under identical loads with capture both off and on. A slow or absent
capture subscriber never blocks forwarding.

## Fourth delivery: user control and release migration

Expose `telar proxy on`, `off` and `status` through the GUI and CLI, scoped to
the explicitly selected machine. Report unsupported coverage or failed
activation honestly. Define remote control forwarding separately from local
activation, using the existing authenticated SSH connection model.

Specify compatibility for processes that already inherited `HTTPS_PROXY` before
switching the runtime to the external service. Those processes retain the old
endpoint and trust environment. Decide stable endpoint handover and opaque
forwarding while activation is off before retiring the Zig listener.

Expand coverage to UDP, including an explicit DNS and QUIC policy. QUIC forwarding
and HTTP/3 inspection are separate capabilities. Define loopback, local-network
and other-protocol behavior, and verify coexistence with VPNs, network changes
and sleep/resume before advertising machine-wide coverage.

Extend builds, CI, installers, macOS signing and Linux packaging to ship the
service and native adapters. Pin the Go toolchain and pair the component versions.
Specify startup, upgrades, uninstall and redirection cleanup for each platform.
Retire the runtime's Zig proxy only after the replacement passes compatibility
and packaged-install checks.

Completion: an installed Telar controls the proxy on each supported platform,
retains panes across on/off and service recovery, preserves trust uninstall,
and declares tested coverage and existing-flow behavior. A clean install and
upgrade both locate compatible components without hardcoded development paths.
