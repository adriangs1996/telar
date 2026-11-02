# Transparent TCP redirection

The C++ runtime has a macOS adapter using a private utun interface and PF rules
for selected local TCP connections. Native loopback acceptance passed for IPv4
and IPv6 on macOS 26.6.2 ARM64 on 2026-10-25. The check verified actual forwarding
through the runtime, original destinations, binary data, half-closes, an
unselected destination and direct connections after cleanup.

The path preserves the application's original IP and port without
proxy environment variables or CONNECT. A privileged helper accepts the
redirected connection, connects to that original destination and passes both
connected sockets to the unprivileged runtime. The existing proxy worker owns
subsequent byte forwarding, connection limits and half-closes. Activation needs
sudo and C++ only; it does not require a Network Extension or Apple signing.

On 2026-10-27, the user reported a successful combined native run extending
acceptance to a controlled IPv4 LAN origin, concurrent helpers, exclusive
endpoint ownership, helper crash recovery and runtime crash cleanup. The
surviving helper retained its loopback lease, and final cleanup restored the
original PF loopback flag. VPN and interface-bound traffic remain unverified.
Syntax validation alone does not prove forwarding or coverage beyond the
tested destinations.

## Native findings

The initial implementation failed because PF skipped `lo0`. After clearing
skip, its outbound rule matched the SYN, but the tagged inbound filter and
`rdr` rule still matched zero packets. The tagging assumption in that
implementation is unsafe on the loopback path.

The public XNU implementation provides an explanation consistent with those
counters. [`lo_tx_compl`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_loop.c)
calls `mbuf_set_status`, which calls
[`driver_mtag_init`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kpi_mbuf.c).
That initializer clears driver metadata that shares the
[`builtin_mtag` union](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/mbuf.h)
with PF metadata. The cleared bytes overlap the packet's PF tag. This is a
source-based explanation, not instrumentation of the running kernel.

Removing the tag guard would also remove the selected-account boundary on
loopback and could intercept the helper's own upstream connections. It is not
a fix for that design. The current implementation instead discovers each
selected flow through a private utun and installs an exact tuple rule before
injecting the first SYN on loopback. It retains the sudo-only deployment model.

## Scope

Activation selects up to 16 numeric IP/port destinations. The default `outbound`
direction selects TCP connections created by the runtime's non-root account.
Native forwarding and socket handoff
are verified for IPv4 and IPv6 loopback and a controlled IPv4 LAN destination. The
adapter does not select other accounts, UDP or ICMP. The privileged CLI accepts
numeric destinations only.
Scoped/link-local IPv6 addresses are rejected. Existing connections are not
retroactively redirected.

The Lua administration API also accepts exact DNS names in `targets`, such as
`"example.test:443"`. The unprivileged runtime uses its existing bounded hostname
resolver, with a three-second selection deadline, and supplies only numeric
destinations in the sudo argument array. A selection may contain at most 16
distinct resolved IP/port pairs. Duplicate DNS addresses are coalesced; failed,
over-capacity, multicast or scoped resolutions reject the selection before any
privileged command runs. Numeric duplicate inputs remain an error.

This is an activation-time address snapshot, without automatic DNS refresh or
wildcard expansion. Stop and start to resolve again. Shared addresses select
connections for every hostname using that IP/port; TLS `intercept_hosts` still
controls which SNI names may be decrypted. Address selection does not prove an
exact hostname match. DNS resolution, bounds, cancellation and the numeric-only
authorization command pass native tests. On 2026-10-30, the user reported the
privileged Desktop Lua check with `localhost` passing: activation of its DNS
snapshot, exact binary forwarding over the selected IPv4 connection,
acknowledged redirect cleanup and restored direct connections. This does not
establish PID selection or forwarding over every address returned by DNS.

Optional process selection accepts up to 16 explicit PIDs with `--process PID`.
The helper pins each PID to its process start time and checks ownership of the
complete TCP tuple using macOS process/socket inspection. Only processes running
under the runtime account qualify. Children are not selected implicitly. The
Lua API pins the process before invoking sudo and passes its birth identity as
`PID@SECONDS.MICROSECONDS`, so PID reuse during authorization does not select a
replacement process. Process inspection and rule syntax pass native unit tests.
On 2026-10-30, the user reported native PID-selected forwarding passing for
IPv4/IPv6 loopback and IPv4 LAN, with excluded processes retaining direct paths,
binary relay, original destinations, cleanup and PF loopback restoration.

TLS bytes pass through unchanged by default. With `transparent_tls = true`,
the runtime probes ClientHello and applies `intercept_hosts` using SNI or the
original numeric address. The existing CA and origin verification then supply
TLS inspection and HTTP observations. See [flow events and hooks](traffic-flows.md).
The redirect helper does not hold CA keys or install trust.

Interface packet observation remains independent. See
[traffic-capture.md](traffic-capture.md) for the Lua subscriptions.

### Incoming selection and acceptance boundary

`--direction inbound` selects new incoming connections to destinations assigned
to active non-loopback interfaces. `--direction both` combines outgoing selection
for every target with incoming selection only for its local targets; it requires
at least one local target. `outbound` remains the default. The Lua administration
API accepts the same `direction` strings. Incoming/both selection cannot be
combined with `processes`; PID attribution remains outbound-only.

The public XNU
[`pf_socket_lookup`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf.c)
handles `PF_IN`, tries exact PCB matches and falls back to wildcard listener
lookup for IPv4 and IPv6. This is a source-level basis for account-scoped
incoming discovery; it does not establish forwarding on the running kernel.

Incoming discovery uses the helper's private PF log and exact-tuple translation
after loopback reinjection of the selected SYN. The incoming listener binds only
the selected local destination address, and its NAT mapping changes only the
destination port. Established remote ACK/data packets can then use their NAT
state on the physical interface without acquiring a loopback destination.
Outgoing-only listeners retain their loopback binding. Connections accepted by
an incoming listener still require the selected source tuple and a matching
reverse NAT lookup before origin connection or runtime handoff.
Discovery excludes `lo0`, preventing the root helper's local
origin connection from becoming a new incoming candidate. A destination that is
no longer assigned to an active non-loopback interface aborts the helper and
runs its existing cleanup. After the root-created origin socket connects, a
bounded native `net.inet.tcp.pcblist64` snapshot verifies the reverse connected
tuple's server account before handoff. The snapshot is capped at 4 MiB, validates
the SDK record layouts and is erased when released. It does not inspect payloads
or deliver host socket tables to Lua. An absent or different peer account is
not handed to the runtime; snapshot errors stop the helper and trigger cleanup.

Incoming process attribution requires a separate ownership contract. A PID
holding a listening descriptor does not prove which process will accept a
connection when descriptors or ports are shared. Outbound full-tuple ownership
must not be reused as proof of an incoming acceptor's identity.

Local-address rejection, directional PF syntax, log validation, request encoding
and real IPv4/IPv6 peer-account inspection pass native tests. The actual
unprivileged controlled-host check has also passed incoming authenticated binary
echo, half-closes, startup, PF syntax and direct connections after shutdown.
On 2026-10-30, the user reported incoming-only IPv4 forwarding through PF
passing after the address-preserving correction: authenticated binary relay,
half-closes, excluded incoming destinations, direct local-client connections,
restored direct paths after shutdown and PF loopback restoration. The user then
reported the separate `both` run passing on the same date, including incoming
remote traffic, selected outgoing traffic, redirected local-client connections,
exclusions and restoration after shutdown:

```sh
/usr/bin/python3 services/runtime-cpp/tools/check_incoming.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --ssh-client CONTROLLED_HOST --live
```

Omit `--live` for preparation and syntax checks without changing PF. Add
`--direction inbound` to test incoming-only scope; the default `both` additionally
checks selected outgoing traffic and the local-client path. `--ssh-address IP`
selects the controlled machine's address. The remote client needs SSH and Python;
the local origins are temporary authenticated processes and stop with the check.
Live mode additionally verifies an excluded incoming destination, binary relay,
half-closes, restoration of direct paths and the original PF loopback flag.
The controlled SSH fixture currently uses IPv4. It does not prove incoming IPv6
forwarding; that needs a controlled non-loopback IPv6 client and local address.
Forwarding acceptance covers the reported outgoing paths and the incoming-only
and combined IPv4 modes. Incoming IPv6 remains unverified.

On 2026-10-30, the first incoming-only native run timed out reading the origin
authentication response. Its diagnostics showed SYN discovery without any
runtime connection. The subsequent address-preserving listener/NAT correction
has native listener binding/binary-transfer tests and IPv4/IPv6 PF syntax
coverage, followed by the user-reported passing privileged incoming-only IPv4
run and the separate passing combined-mode IPv4 run. See XNU's
[PF state handling](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf.c)
and [IPv4 loopback address checks](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/ip_input.c).

## Enable ingress

Configure the C++ runtime and restart it as your ordinary account:

```lua
return {
  api_version = 2,
  runtime = {
    proxy = {
      enabled = true,
      transparent_redirect = true,
    },
  },
}
```

This creates a private `<runtime socket>.redirect` endpoint. It accepts socket
handoffs only from root. Received descriptors must be connected IP stream sockets,
and the upstream socket must match the advertised original IP/port. A normal
same-user client cannot bypass CONNECT authentication through this endpoint.

## Review and activate

Validate the generated PF syntax without changing rules or PF enable references:

```sh
/path/to/telar-runtime traffic redirect \
  --socket /path/to/runtime.sock \
  --target 192.0.2.10:443 \
  --target '[2001:db8::10]:443' \
  --dry-run
```

Replace these documentation addresses with your selected destinations. Only the
helper is elevated for activation:

```sh
sudo /path/to/telar-runtime traffic redirect \
  --socket /path/to/runtime.sock \
  --target 192.0.2.10:443
```

Add `--process PID` to restrict that destination selection to explicit processes.
Repeat the option for additional processes. Without it, selection covers the
runtime account as before.

The helper stays in the foreground. Ctrl+C, SIGTERM or runtime disconnection
remove its private translation/filter rules, then release
its PF enable reference. Closing Desktop does not terminate the helper or runtime.
Stopping the runtime closes its adopted connections.

The main PF ruleset must already expose `rdr-anchor "com.apple/*"` and
`anchor "com.apple/*"`. Missing hooks fail activation. The adapter does not
replace the main ruleset, change interface addresses, alter routing tables,
enable global IP forwarding, or edit `/etc/pf.conf`. External PF reloads or
rules that override the adapter can still prevent interception.

## Loopback filtering

PF cannot evaluate these rules while `lo0` has its skip flag set. After loading
its private anchor, the helper clears only `PFI_IFLAG_SKIP` on `lo0` through
Darwin's `DIOCCLRIFFLAG` ioctl, then verifies the result with `pfctl`. The last
helper restores the flag with `DIOCSETIFFLAG` if it was originally set. Other
interface flags and the global PF ruleset are left intact. See Apple's
[PF interface ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pfvar.h).

Enabling loopback filtering also subjects other loopback traffic to the
machine's existing PF rules for that interface. The adapter's own rules still
select only the configured account and destinations.

Helpers coordinate through the root-owned `loopback` recovery record under
`/var/run/telar-redirect`. It records the original skip setting and up to 64
helper identities. A separate lock serializes updates, so one helper stopping
does not restore skip while another still owns a lease. The record is saved
before clearing the flag. Failed changes and restoration retain enough state
for the same endpoint's `redirect-cleanup` command to retry after a crash.

## Flow discovery and loop prevention

The helper creates a private utun and attaches IPv4/IPv6 protocol handlers
without adding addresses, changing default routes, or diverting whole subnets.
A PF outbound rule selects new TCP SYNs by
account and destination and routes only those packets to that interface.
After validating the packet, the helper installs an exact source/destination
address and port rule and reinjects the SYN on `lo0` using BPF. Subsequent
packets of that tuple use the loopback path and the kernel's TCP/NAT state.
No PF packet tag has to survive the interface crossing, and no TCP stack is
implemented in userspace.

IPv6 loopback needs a separate discovery source: XNU's `nd6_output` rejects
packets containing `::1` on non-loopback interfaces before utun can deliver
them. For destinations at `::1`, the helper allocates a private `pflog` clone,
logs only the selected SYNs there, verifies the logged UID/direction/action and
reinjects them directly on `lo0`. The clone index is saved with the endpoint's
recovery record and removed during cleanup. Existing log interfaces are not
reused or removed.

Process selection uses that private PF log for all discovery packets, preserving
their original interface. A socket-owner match receives the translation rule.
Other flows receive a short-lived exact-tuple bypass using the original
interface and its read-only routing lookup; they receive no translation rule.
The helper rechecks ownership before handing a selected socket to the runtime.
An incomplete ownership scan cannot authorize interception.

The translation rule cannot match the helper's distinct upstream tuple.
Root-owned egress sockets also do not match the selected account's outbound
rules, including when the destination itself is loopback. Accepted sockets
must match a discovered peer and pass `DIOCNATLOOK` verification for the original
destination; directly connecting to a helper listener does not authorize handoff.

At most 256 discovered flows exist at once. An unadopted flow expires after ten
seconds. A control socket stays open for each adopted runtime connection; when
the runtime closes it, the helper removes that flow's rules. Private anchor
updates do not replace global rules. `--dry-run` prints the initial discovery
rules using the placeholder interface `utun0`; activation uses the name assigned
by the kernel. The utun disappears when the helper closes its descriptor.

The helper creates egress sockets before passing their descriptors. PF uses
the socket's credentials for its UID lookup; transferring the descriptor does
not require the runtime to become root. See Apple's
[socket lookup implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/in_pcb.c).

The helper has 32 pending upstream connections, a ten-second connect deadline
and a two-second runtime acknowledgement deadline. Socket handoff has its own
bounded queue. Runtime transport uses the proxy's existing 256-connection policy.
The helper reinjects the initial SYN, including any TCP Fast Open payload, but
does not relay established application streams or execute user scripts.

## Recovery

One helper holds an exclusive root-owned lock for each runtime endpoint. Its
PF anchor identity derives from that endpoint. The enable-reference token and
full endpoint are stored under `/var/run/telar-redirect`, accessible only to root.

SIGKILL or a crash can leave PF state behind. The next activation recovers the
recorded changes before loading new rules. To recover without activating again,
use the same runtime socket path, even if that runtime is no longer running:

```sh
sudo /path/to/telar-runtime traffic redirect-cleanup --socket /path/to/runtime.sock
```

Recovery refuses to race a live helper. It flushes only that anchor's rules and
translation rules, releases its loopback lease and releases only its saved
enable reference. macOS does not
support killing states by rule label. Existing states expire normally; stopping
the runtime closes its adopted sockets. Recovery never flushes global states,
kills connections by host, or disables PF globally. If either rule flush fails,
both flushes are attempted and the reference and recovery record are retained
for a retry. Failed loopback restoration also retains the lease and enable
reference. Cleanup errors are reported on stderr.

Recovery records also retain the private log-interface index. Once the enable
reference has been released, a zero token marks pending file/interface cleanup,
so a retry does not release the same reference twice.

## Verification

From the repository root:

```sh
cmake --build services/runtime-cpp/out --target telar-runtime redirect-tests tls-tests
ctest --test-dir services/runtime-cpp/out -R '^(redirect-tests|redirect-check-tests|tls-tests)$' --output-on-failure
python3 services/runtime-cpp/tools/check_redirect.py --runtime services/runtime-cpp/out/telar-runtime
```

The tests cover native PF syntax, target validation, startup rollback and stale
record recovery with injected commands, shared loopback ownership, flag
restoration after failures, authenticated descriptor transfer,
IPv4/IPv6 binary forwarding, server-first traffic, half-closes and preservation
of the actual TLS origin certificate by default. Additional cases verify
opt-in transparent TLS, CA certificate identity, rejected origin trust and
binary non-HTTP TLS forwarding. The process check starts a temporary
unprivileged runtime and runs the real `--dry-run` command without changing PF.

For native acceptance, run this as your account in a terminal:

```sh
python3 services/runtime-cpp/tools/check_redirect.py \
  --runtime services/runtime-cpp/out/telar-runtime --live
```

It asks sudo only for administrative helper operations. It redirects ephemeral
IPv4/IPv6 loopback destinations, verifies the connection took the runtime path
through its distinct upstream source port, checks an unselected destination,
and verifies direct connections and loopback flag restoration after cleanup.
It does not require Internet
traffic or trust-store changes. VPN, interface-bound application traffic and
multiple-account native acceptance remain additional checks.
`check_network.py` combines native capture/Lua, optional controlled SSH echo
destinations and `check_redirect_lifecycle.py` for simultaneous helpers and
recovery after their own process crashes. See [verification](traffic-flows.md#verification).
The user reported that combined check passing with a controlled LAN origin on
2026-10-27; VPN was explicitly skipped.

The separate process-selection acceptance check is:

```sh
/usr/bin/python3 services/runtime-cpp/tools/check_redirect.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --live --process-selection --ssh-origin YOUR_CONTROLLED_LAN_HOST
```

It selects a persistent child process and checks that the verifier's connections
to the same destinations remain direct. Omit `--ssh-origin` for loopback-only
acceptance. On 2026-10-30, the user reported its privileged IPv4/IPv6 loopback
and IPv4 LAN paths passing, together with process exclusion and cleanup.

### Interface-bound socket acceptance

`check_redirect.py --bound-interface IFACE --ssh-origin CONTROLLED_HOST` binds
the remote test socket explicitly to the selected macOS interface before
connecting. It uses `IP_BOUND_IF` for IPv4 and `IPV6_BOUND_IF` for IPv6 and reads
the option back before and after connection. An unavailable interface fails
before connection; a binding error never falls back to an unbound socket.
The SSH fixture currently supplies an IPv4 destination. The option also reaches
the selected child process when combined with `--process-selection`.

```sh
/usr/bin/python3 services/runtime-cpp/tools/check_redirect.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --ssh-origin CONTROLLED_HOST --bound-interface IFACE --live
```

Before activation the bound binary echo must remain direct. Live acceptance
requires a distinct upstream source port and exact binary relay, an excluded
destination, acknowledged cleanup, PF loopback restoration and direct bound
connections again after shutdown. Without `--live`, the checker establishes
only direct bound connectivity, runtime startup and PF syntax.

On 2026-10-30, unprivileged direct IPv4 LAN echo passed with a socket bound to
`en0`, followed by runtime startup and PF syntax checks. Native bound IPv4/IPv6
loopback echo, selected-child binding and missing-interface rejection also pass
the Python regression. The user subsequently reported privileged bound IPv4 LAN
redirection passing on `en0`: binary relay through the runtime, original
destinations, exclusion, direct bound connections after shutdown and PF loopback
restoration. The same run also passed unbound IPv4/IPv6 loopback redirection;
it does not establish bound VPN forwarding or bound remote IPv6.

### Earlier native result and diagnostics

The original loopback-only native run reported:

```text
IPv4 native TCP redirect and binary relay verified
IPv6 native TCP redirect and binary relay verified
Native IPv4/IPv6 TCP redirect, original destinations, binary data and exclusion verified
Redirect cleanup, PF loopback restoration and direct connections after shutdown verified
```

Failed checks preserve their private temporary directory and print its path.
`failure.log` keeps the original traceback, `runtime.log` and `helper.log` keep
process output, and `pf-diagnostics.log` records rules, states, counters and loopback
skip flags before cleanup. Cleanup failures are reported separately in
`cleanup-errors.log` and do not replace the original failure. Successful checks
remove their temporary files.
