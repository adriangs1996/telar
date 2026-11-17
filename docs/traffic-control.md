# Runtime traffic administration

`telar.traffic` exposes asynchronous native administration alongside
[observation and interception](traffic-flows.md). The runtime owns the operation;
closing a window or cancelling a callback does not undo an accepted change.

Enable observation and explicitly grant administration in runtime configuration:

```lua
return {
  api_version = 2,
  runtime = {
    proxy = {
      enabled = true,
      network_capture = true,
      network_control = true,
      transparent_redirect = true,
      transparent_tls = true,
      stream_interception = true,
      intercept_hosts = { "*.example.test" },
    },
  },
}
```

`network_control` defaults to false and requires `network_capture`. Without that
grant, status and public certificate export remain available; mutations return
`result = "disabled"`. This is an account-level grant. [Persistent runtime Lua
workers](traffic-workers.md) additionally require digest-bound `traffic.control`
for mutations. The native service validates that permission and its live lease
independently of Lua. Recording operations instead require `traffic.record` and
remain restricted to the package's own namespace. Every granted traffic capability
allows status and public CA export; `administration_enabled` reflects the caller's
effective global/package authorization.

## Lua API

```lua
local traffic = require("telar.traffic")
local cancel = traffic.status(function(err, reply)
  assert(not err, err)
  print(reply.capture.state, reply.redirect.state, reply.proxy.tls_accepting)
end)

traffic.capture.start(function(err, reply)
  assert(not err, err)
  if reply.result == "authorization_required" then
    -- Present reply.authorization_argv for terminal authorization.
  end
end)
traffic.redirect.start({targets = {"192.0.2.10:443", "[::1]:8080"}}, function(err, reply) end)
traffic.redirect.start({targets = {"192.0.2.10:443"}, processes = {1234}}, function(err, reply) end)
traffic.redirect.start({targets = {"example.test:443"}}, function(err, reply) end)
traffic.redirect.start({targets = {"192.0.2.10:8080"}, direction = "inbound"}, function(err, reply) end)
traffic.capture.stop(function(err, reply) end)
traffic.redirect.stop(function(err, reply) end)
traffic.ca.certificate(function(err, reply)
  assert(not err, err)
  print(reply.ca.fingerprint_sha256)
  -- reply.ca.certificate is public PEM, never the private key.
end)
traffic.ca.install(function(err, reply) end)
traffic.ca.uninstall(function(err, reply) end)
traffic.ca.rotate(function(err, reply) end)
cancel()
```

Every function returns a cancellation function. Transport/framing failures arrive
as `err`. A native reply has `result = "ok"`, `disabled`, `authorization_required`,
`busy`, `failed` or `cleanup_required`, a bounded `message`, and current status.
Inspect `result` before treating an operation as successful. Numeric destination
syntax and duplicate targets are validated before invoking a privileged command.
Exact DNS names are resolved by the unprivileged runtime before sudo, with a
three-second deadline and at most 16 distinct numeric destinations. DNS aliases
may share an address; duplicate resolved addresses are coalesced. Failed or
over-capacity resolution changes no PF rules. `authorization_argv` contains the
resolved numeric snapshot, never a hostname for the root helper to resolve.

| Reply field | Meaning |
| --- | --- |
| `administration_enabled` | Configuration grants mutations |
| `capture.state` | `disabled`, `idle`, `live` or `offline` |
| `capture.session_id` | Decimal identity; `0` before helper metadata arrives |
| `capture.interfaces`, `capture.interface_errors` | Notifications received from the current helper |
| `redirect.state` | `disabled`, `idle`, `starting`, `active`, `stopping` or `cleanup_required` |
| `proxy.active`, `proxy.port` | Local proxy availability and listener |
| `proxy.transparent_tls`, `proxy.interception` | Configured capabilities |
| `proxy.tls_accepting` | A synchronized signer is available for new inspected TLS sessions |
| `ca.trust_record` | Local installation record: `absent`, `installed` or `stale` |
| `ca.fingerprint_sha1`, `ca.fingerprint_sha256` | Active signer fingerprints; SHA-1 identifies the macOS removal target |
| `ca.certificate` | Public PEM for certificate requests; otherwise empty |
| `authorization_argv` | Exact terminal authorization/recovery argument array |

`trust_record` checks Telar's persisted record and authority consistency. It does
not independently verify the keychain or a browser's private trust store. Apps
can cache an earlier root bundle; export lets the user configure private stores.

## Native lifecycle

A private same-user `.network` socket has its own worker, independent of packet,
proxy and terminal workers. Peer counts, frames, I/O and commands are bounded.
Each connection issues one request. No Lua, shell source, caller-selected
executable or CA key crosses into a privileged helper. The administration socket
exists when `network_capture` is enabled.

[Recordings](traffic-recordings.md) reuse this channel with bounded cursor pages.
They require account-level observation and do not require `network_control`.
Legacy administration request/reply frames retain their existing encoding.

Start checks the exact helper command through noninteractive sudo policy
inspection, then invokes `/usr/bin/sudo -n --` with the current runtime executable
and validated arguments. It cannot collect passwords. If authorization is
unavailable, `authorization_argv` supplies a terminal invocation without `-n`.
An externally authorized helper appears in the same status and can be stopped by
the API. Networking remains C++ with sudo, without a signed Network Extension.

Capture becomes live when a root-authenticated producer connects; interface
events establish usable coverage. Stop closes that producer's data channel and
waits for the service's acknowledgement. The helper releases its devices on
disconnect. Subscribers and existing proxy connections remain independent.

Redirect becomes active only after the helper acknowledges loading PF rules.
Stop uses its existing monitor channel; the helper removes its rules and restores
its loopback lease before acknowledging cleanup. A crash/disconnect without that
acknowledgement reports `cleanup_required` and supplies the recovery command.
Existing selected proxy sockets can finish after redirect rules are removed.

The [adapter's selection limits](transparent-redirect.md) still apply: up to 16
resolved numeric destinations, new local-account TCP connections, one helper per endpoint.
An active redirect start returns `busy`; stop before changing its selection.
Optional `processes` selects 1..16 explicit PIDs under the runtime account. The
runtime and helper pin process start identities; descendants are not implicitly
selected. Omitting the array preserves account-wide destination selection.
Process lookup, tuple matching and syntax pass native tests; process-selected
forwarding still requires its privileged acceptance run. DNS selection resolves
once at activation; stop and restart to refresh it. It does not expand wildcards
or distinguish names sharing an IP/port. TLS `intercept_hosts` remains a separate
SNI policy. Domain-selected privileged forwarding and automatic DNS refresh
remain pending. `direction = "inbound"` selects only
active non-loopback local destinations; `"both"` combines those incoming targets
with all selected outbound targets and requires at least one local destination.
Incoming/both mode rejects `processes` and verifies the connected origin server's
account before handoff. Incoming-only and combined IPv4 forwarding passed native acceptance;
see [incoming selection](transparent-redirect.md#incoming-selection-and-acceptance-boundary).
Flow event direction still describes client-to-server/server-to-client bytes,
independently of the redirect activation's network direction.

## Authorities

Install/remove/rotate reuse the native trust service and fixed macOS keychain
commands. Install/remove can trigger OS authorization. Rotating without an
installation record replaces the private CA without changing OS trust. Rotating
an installed CA replaces its trust entry. Uninstall returns to the private CA.
Removal during uninstall, rotation and rollback uses fingerprint-scoped
`security delete-certificate -t -Z` in the recorded login keychain, requesting
removal of both the certificate and its user trust settings. The exact command
and partial OS trust-command rollback are covered by injected-command tests.

Each TLS session retains its signer. A pending handshake keeps its original CA;
new sessions use the replacement. Stable `ca-active-cert.pem` and `ca-bundle.pem`
paths are updated for newly launched processes. A change suspends new inspected
TLS sessions while synchronizing the store, files and signer. If synchronization
fails, `tls_accepting` stays false until a successful retry; established sessions
can continue. The existing startup trust maintenance still applies.

## Verification

```sh
cmake --build out/dev --target telar-runtime traffic-control-tests tls-tests redirect-tests
ctest --test-dir out/dev -R '^(traffic-control-tests|tls-tests|redirect-tests)$' --output-on-failure
```

Native tests cover fragmented/malformed IPC, mutation denial, connected producer
stop, redirect activation/cleanup/crash states, CA lifecycle and synchronization
failure/retry. Actual SSL peers verify handshakes created on either side of a
rotation use their authenticated signer and transfer data. Certificate-store
tests inject commands and do not alter the runner's keychain.

Observation events can be dropped by the bounded runtime/subscriber queues,
with explicit loss counters, so they must not serve as reliable administration
acknowledgements.
