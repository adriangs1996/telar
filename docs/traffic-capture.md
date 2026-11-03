# Traffic subscriptions on the C++ runtime

The C++ runtime publishes interface packets, UDP/ICMP datagrams, reconstructed TCP flows, forwarded
streams and captured HTTP exchanges to Desktop Lua. Selected local TCP
connections use the [transparent PF adapter](transparent-redirect.md).
[Flow events, transparent TLS, asynchronous stream hooks and the Lua inspector](traffic-flows.md)
are implemented separately from capture activation. Repeater workflows belong
to client applications. The broader target is in
[traffic-platform.md](traffic-platform.md).

The runtime runs natively on macOS and Linux. Go is a reference only; none of
these commands starts the Go service. The capture helper links the platform's
libpcap. The PF transparent-redirection helper remains specific to macOS.

## Enable the data service

Add this C++ runtime option to your configuration, preserving your other settings:

```lua
return {
  api_version = 2,
  runtime = {
    proxy = {
      network_capture = true,
    },
  },
}
```

Restart the C++ runtime with that configuration. It creates a private traffic
data socket beside its runtime socket. Packet delivery runs separately from
terminal control and from the forwarding loop. Closing Desktop cancels its
subscriptions; the runtime and capture helper continue until stopped.

## Capture active interfaces

Start only the capture command with administrative privileges:

```sh
sudo /path/to/telar-runtime traffic capture --socket /path/to/runtime.sock
```

The runtime and Desktop keep running as your account. The helper observes
active physical, loopback and virtual interfaces, including VPN interfaces
exposed by the OS. It scans for interface changes every second and reports
open, close and error events. It does not change routes, firewall rules or
certificate trust. Stop the helper with Ctrl+C. Runtime disconnection also
ends the helper.

Interface lifecycle events carry the OS interface index as well as its name.
These values are not lifetime identifiers: XNU can
[recycle an interface while retaining its index](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/dlil.c#L4913).
Apps must delimit observed capture lifetimes with open/close events and clear
their per-lifetime state after closure, even when a later opening has the same
name and index. The one-second scan can miss interfaces that appear and disappear
entirely between scans.
If a name reappears with a different index, the helper closes the old capture
and opens the replacement. A libpcap read failure also closes that capture;
the next scan retries opening an interface that is still active. On 2026-10-30,
the user reported native creation/removal/recreation passing for the owned
virtual-interface fixture described below.

Capture is best effort and non-promiscuous. There are at most 128 capture
interfaces and 32 subscribers. Packets retain their original link type, bytes,
interface name/index, microsecond timestamp and original length. Capture is
limited to 262144 bytes per packet; `truncated` reports shorter captures.
Unsupported protocols remain available as raw bytes.

Permissions, device errors and unavailable interfaces can reduce coverage.
On 2026-10-27, the user reported successful native UDP loopback capture through
the C++ helper and actual Desktop Lua API. The combined check also passed
selected TCP redirection to a controlled LAN host. These are separate results:
LAN redirection does not establish physical-interface packet capture. On
2026-10-30, the user reported the routed capture check passing on `en0` with the
controlled LAN host: exact outbound/inbound binary payloads reached Desktop Lua
with verified interface attribution and cancellation. The user subsequently
reported two native virtual-interface creation/packet/removal cycles reaching
Desktop Lua with identity checks and cancellation. VPN capture remains
unverified. The focused
unprivileged delivery check uses a real PCAP file.

Passive TCP analysis now reconstructs bounded IPv4/IPv6 fragments while raw
subscriptions and PCAPNG recordings keep the original packets. The
`check_traffic.py --fragments` check passes through the actual importer, runtime
and Desktop Lua API, also under AddressSanitizer. See the [fragment limits and
error contract](traffic-flows.md#observe-streams). This offline evidence does not
establish physical-interface capture coverage.

## Subscribe from Desktop Lua

```lua
local traffic = require("telar.traffic")

local stop = traffic.subscribe({
  events = { packet = true },
  filter = "tcp port 443 or udp port 53",
}, function(err, event)
  if err then
    print(err)
    return
  end

  if event.kind == "packet" then
    -- event.bytes is a binary Lua string, including any NUL bytes.
    inspect_packet(event.interface, event.link_type, event.bytes)
  end
end)

-- Calling this more than once is safe, including from the callback itself.
stop()
```

`events` selects `packet`, `exchange`, `flow`, `datagram`, or a combination with boolean fields. The default
is packets. Lifecycle/status events still arrive, including `ready`,
`capture.started`, `capture.stopped`, `interface.open`, `interface.closed`,
`interface.error` and `statistics`. An error callback terminates the subscription.
For interface errors, `event.bytes` contains the capture backend's message.

`filter` is a libpcap/BPF capture expression applied to packets before delivery
to Lua. It is not a Wireshark display filter and does not filter HTTP exchange
or flow/datagram events. The service compiles it separately for each observed link type. A
filter that cannot compile for that type ends that subscription.

Each event includes `session_id`, `sequence`, `offline`, `visibility`,
`subscriber_drops`, `kernel_drops`, `capture_drops` and `runtime_drops`. Identities
and 64-bit counters are decimal strings to avoid LuaJIT number precision loss.
Interface indices, lengths and microsecond timestamps are numeric. Kernel
drop measurements come from capture-helper statistics; runtime heartbeats
report runtime publication drops separately. Packet `visibility` is `wire`;
it never implies that TLS was decrypted.

Helper-originated events carry the last observed cumulative `kernel_drops` for
their capture session, including packet and interface lifecycle events. Counts
from closed interfaces remain in that total. Reopening a device starts a new
per-device sample without resetting the session count; 32-bit backend counter
wraps are accumulated into the 64-bit total. The helper tries a final statistics
read before publishing an interface close. If that read fails, it retains the
last successful sample. Derived flow/datagram events retain their source
packet's snapshot; runtime heartbeats report a separate loss domain.

These are the losses reported by libpcap, not a measurement of every possible
driver or hardware drop. In particular, a zero backend counter can mean that
the measurement is unavailable. See [libpcap's statistics contract](https://www.tcpdump.org/manpages/pcap_stats.3pcap.html).

Subscriptions have independent eight-frame queues. Dropping an event increments
that subscriber's cumulative counter; loss does not stop forwarding or another
subscriber. The helper also counts unsent frames when the data channel is full.
A partially sent frame must finish within one second or the helper disconnects,
so subsequent frames cannot be mistaken for the missing remainder. A new capture
has a new identity. Disconnection is visible and never implies lossless recovery.
One live capture or offline import source can publish at a time.

## Receive HTTP plaintext

Use the existing C++ TLS proxy configuration to select hosts, enable HTTP
capture and manage its CA:

```lua
proxy = {
  enabled = true,
  network_capture = true,
  intercept_hosts = { "api.example.com" },
  capture = { enabled = true },
}
```

This table belongs under `runtime` in the configuration. Applications must use
the authenticated explicit proxy and trust its selected CA. The existing
`telar-runtime proxy trust install|status|uninstall` commands manage system
trust; `--ca-dir` selects the authority directory. The existing pane environment
injection supplies proxy credentials and certificate paths to supported child
applications. Arbitrary applications outside Telar need their own proxy/trust
configuration. The interface capture helper does not redirect them.

```lua
local stop = require("telar.traffic").subscribe({
  events = { exchange = true },
}, function(err, event)
  if err or event.kind ~= "exchange" then
    return
  end

  local exchange = event.exchange
  if exchange.host == "api.example.com" then
    inspect_http(exchange.method, exchange.target, exchange.request, exchange.response)
  end
end)
```

An exchange includes its protocol, host, method, target, connection/stream
identities and timing. Request and response halves can be absent on failure or
join timeout. Each present half contains ordered header fields, raw headers,
body bytes, encoding/decoding status, status code, outcome and truncation flags.
The app delivery clips each header/body part at 48 KiB and marks truncation;
it does not change forwarding or the original capture delivered to plugins.

These observations happen after capture. Changing an event table changes only
the app's copy. Register a separate [stream hook](traffic-flows.md#decide-before-forwarding)
to decide before forwarding. HTTP plaintext does not establish a correlation
with a particular passive packet. Transparent TLS inspection can use the same
CA and HTTP delivery after `transparent_tls` is explicitly enabled.

Installing a CA alone does not decrypt passive TLS captures. It requires an
accepted active MITM or endpoint session secrets. See the
[TLS decryption requirements](https://wiki.wireshark.org/TLS/).

## Check delivery without root

Import a PCAP through the same data channel. Every imported event is labelled
`offline = true`; an ordinary peer cannot claim to be the live privileged helper.

```sh
/path/to/telar-runtime traffic import --socket /path/to/runtime.sock --file capture.pcap
```

From the repository root, run the focused checks:

```sh
cmake --build services/runtime-cpp/out --target telar-runtime traffic-tests plugin-tests tls-tests
ctest --test-dir services/runtime-cpp/out -R '^(traffic-tests|plugin-tests|tls-tests)$' --output-on-failure
cmake --build services/desktop-mode/out/debug --target traffic_dbg
python3 services/runtime-cpp/tools/check_traffic.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg
```

The cross-process check starts an isolated runtime with a private temporary
directory and in-memory history. It imports a PCAP and verifies the real
Desktop Lua API, native BPF filtering, exact binary payload and cancellation
inside the callback. It leaves the regular runtime and OS trust untouched.

To check actual loopback capture, run this as your account in a terminal. It
requests sudo for the capture helper, keeps its temporary runtime unprivileged,
checks exact UDP bytes and interface attribution, and shuts both down. Add
`--lua-probe services/desktop-mode/out/debug/traffic_dbg` to verify the real Lua path:

```sh
python3 services/runtime-cpp/tools/check_traffic_live.py \
  --runtime services/runtime-cpp/out/telar-runtime
```

This establishes loopback acceptance only. Physical interfaces, VPN devices
and interface changes still need native coverage tests.

The verifier also has an optional controlled-host check for a routed interface:

```sh
/usr/bin/python3 services/runtime-cpp/tools/check_traffic_live.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg \
  --ssh-origin CONTROLLED_HOST
```

It starts the existing authenticated temporary TCP echo origin, inspects the
destination's actual routing interface and requires the outbound and inbound
binary markers on that interface in native subscriptions and Desktop Lua.
The helper remains the only elevated process. `--ssh-address IP` selects the
echo address; `--expected-interface IFACE` additionally requires that route.
Loopback routes cannot satisfy this check. A virtual/VPN route establishes
observation at that virtual interface, without claiming its underlying physical
link. The temporary echo server stops when its SSH owner closes.

Add `--bound-interface IFACE` to bind the remote test socket explicitly to that
macOS interface. The checker reads back its kernel binding before and after
connect and requires the two binary capture markers on that selected interface
in both native subscriptions and Desktop Lua. This does not infer the binding
from the default route. `check_network.py` forwards the same option to its LAN
capture and redirect stages, including the selected child when `--selection` is
used. The optional separate VPN stages retain their own destination/interface
selection. On 2026-10-30, the user reported native bound IPv4 LAN capture on
`en0` passing: outbound/inbound binary payloads reached Desktop Lua with verified
interface identity and cancellation. The separate bound redirection check also
passed remote binary relay, exclusions, direct connections after shutdown and
PF loopback restoration. These results cover the exercised IPv4 LAN binding;
bound VPN traffic remains unverified.

`check_network.py --ssh-origin ...` now includes that routed capture check before
redirection. Its optional VPN arguments also run capture with the specified VPN
interface. The user reported the privileged `en0` routed-capture stage passing on
2026-10-30. The subsequent interface-lifecycle stage failed in the Lua verifier's
assumption that OS indices could never recur. The corrected checker requires a
fresh open/packet/close cycle for each recreation and accepts reused indices.
The user subsequently reported the focused native interface-lifecycle check
passing on the same date.

The optional virtual-interface fixture creates only its own temporary `utun`,
injects a binary loopback-addressed UDP packet on it, closes it, and repeats the
cycle. It reuses the runtime's C++ private-tunnel setup. No existing interface,
PF rule, configured route or trust store is changed. The fixture exits and
releases its tunnel when its owner closes stdin, or after 30 seconds without a
command. With `--lua-probe`, Lua must observe each open, exact binary packet and
close, including the corresponding nonzero interface index, before cancelling.
The index must remain consistent within each observed cycle; a later cycle may
reuse it. A Lua regression covers both reused and changed indices, missing
openings, stale packets, mismatched indices and duplicate openings.

```sh
cmake --build services/runtime-cpp/out --target traffic-interface-probe
/usr/bin/python3 services/runtime-cpp/tools/check_traffic_live.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg \
  --interface-probe services/runtime-cpp/out/traffic-interface-probe
```

The same `--interface-probe` argument enables this stage in `check_network.py`.
The fixture's packet framing, checksum and datagram decoder checks pass without
root in normal and AddressSanitizer builds. Separately, the user reported native
sudo acceptance on 2026-10-30: loopback capture, actual Desktop Lua binary packet
delivery/cancellation and two virtual-interface creation, binary capture,
removal and recreation cycles through Lua. This does not establish capture of
a configured VPN's tunnel traffic or physical adapter removal.
