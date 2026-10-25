# Traffic subscriptions on the C++ runtime

The C++ runtime can publish interface packets and captured HTTP exchanges to
Desktop Lua. This is an initial observation API. Transparent routing, generic
TCP reassembly, interception decisions, rewriting and retained queries are
still pending. Repeater workflows belong to client applications. The broader
target is in [traffic-platform.md](traffic-platform.md).

The runtime currently targets macOS ARM64. Go is a reference only; none of these
commands starts the Go service. The capture helper links the SDK's libpcap.

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

Capture is best effort and non-promiscuous. There are at most 128 capture
interfaces and 32 subscribers. Packets retain their original link type, bytes,
interface name/index, microsecond timestamp and original length. Capture is
limited to 262144 bytes per packet; `truncated` reports shorter captures.
Unsupported protocols remain available as raw bytes.

Permissions, device errors and unavailable interfaces can reduce coverage.
The live privileged path has not yet passed native interface acceptance in
this delivery. A manual check is provided below. The automated delivery checks use real PCAP files without
administrative privileges; they do not establish physical-interface coverage.

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

`events` selects `packet`, `exchange`, or both with boolean fields. The default
is packets. Lifecycle/status events still arrive, including `ready`,
`capture.started`, `capture.stopped`, `interface.open`, `interface.closed`,
`interface.error` and `statistics`. An error callback terminates the subscription.
For interface errors, `event.bytes` contains the capture backend's message.

`filter` is a libpcap/BPF capture expression applied to packets before delivery
to Lua. It is not a Wireshark display filter and does not filter HTTP exchange
events. The service compiles it separately for each observed link type. A
filter that cannot compile for that type ends that subscription.

Each event includes `session_id`, `sequence`, `offline`, `visibility`,
`subscriber_drops`, `kernel_drops`, `capture_drops` and `runtime_drops`. Identities
and 64-bit counters are decimal strings to avoid LuaJIT number precision loss.
Interface indices, lengths and microsecond timestamps are numeric. Kernel
drop measurements come from capture-helper statistics; runtime heartbeats
report runtime publication drops separately. Packet `visibility` is `wire`;
it never implies that TLS was decrypted.

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
the app's copy; interception decisions are not implemented yet. HTTP
plaintext from the explicit proxy does not establish a correlation with a
particular passive packet. Raw TCP and opaque TLS streams are not reconstructed
by the observation service yet.

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
checks exact UDP bytes and interface attribution, and shuts both down:

```sh
python3 services/runtime-cpp/tools/check_traffic_live.py \
  --runtime services/runtime-cpp/out/telar-runtime
```

This establishes loopback acceptance only. Physical interfaces, VPN devices
and interface changes still need native coverage tests.
