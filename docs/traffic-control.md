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
is covered by injected-command tests. The browser acceptance check below also
verifies actual user-keychain uninstall and removal of native trust. The
[rotation/recovery check](#rotation-and-publication-failure-recovery) also passed
installed-CA rotation and recovery from a public certificate publication failure.
Partial OS trust-command rollback remains covered by injected-command tests.

Each TLS session retains its signer. A pending handshake keeps its original CA;
new sessions use the replacement. Stable `ca-active-cert.pem` and `ca-bundle.pem`
paths are updated for newly launched processes. A change suspends new inspected
TLS sessions while synchronizing the store, files and signer. If synchronization
fails, `tls_accepting` stays false until a successful retry; established sessions
can continue. The existing startup trust maintenance still applies.

## Verification

```sh
cmake --build src/runtime-cpp/out --target telar-runtime traffic-control-tests tls-tests redirect-tests
ctest --test-dir src/runtime-cpp/out -R '^(traffic-control-tests|tls-tests|redirect-tests)$' --output-on-failure
cmake --build src/desktop-mode/out/debug --target traffic_dbg
python3 src/runtime-cpp/tools/check_traffic.py \
  --runtime src/runtime-cpp/out/telar-runtime \
  --lua-probe src/desktop-mode/out/debug/traffic_dbg --control
```

Native tests cover fragmented/malformed IPC, mutation denial, connected producer
stop, redirect activation/cleanup/crash states, CA lifecycle and synchronization
failure/retry. Actual SSL peers verify handshakes created on either side of a
rotation use their authenticated signer and transfer data. Certificate-store
tests inject commands and do not alter the runner's keychain.

The real runtime/Desktop Lua check verifies status, public certificate export,
persisted private rotation, stop, invalid selection, cancellation and subsequent
packet delivery. It requires no sudo. Native privileged start/stop through this
new control API and browser trust are separate acceptance checks.

The privileged API check is ready for an ordinary terminal with sudo access:

```sh
sudo -v && /usr/bin/python3 src/runtime-cpp/tools/check_traffic.py \
  --runtime src/runtime-cpp/out/telar-runtime \
  --lua-probe src/desktop-mode/out/debug/traffic_dbg --control-live
```

It starts/stops native capture through Lua, verifies a real loopback UDP packet,
starts PF redirect through the same API, verifies changed source ports and exact
binary echo, stops redirection with cleanup acknowledgement, and proves direct
connections recover. It uses ephemeral local ports and does not install OS trust.
Failed checks preserve their private diagnostic directory. The combined
`check_network.py` now includes both administration checks.

The live checker waits for its driver to verify the full binary exchange before
asking Lua to stop redirection. A private stdin continuation coordinates this
test step; it does not depend on delivery of `flow.close`. Observation events
can be dropped by the bounded runtime/subscriber queues, with explicit loss
counters, so they must not serve as reliable administration acknowledgements.
The runtime's stop reply and the subsequent direct binary connection remain
mandatory acceptance checks. Stage traces are written to the probe diagnostics
and printed if the check fails.

The regression below exercises the actual runtime, Desktop Lua, a binary proxy
relay and a control reply while deliberately subscribing to no flow events. It
requires neither sudo nor OS trust changes:

```sh
/usr/bin/python3 -B src/runtime-cpp/tests/network_check_test.py \
  --runtime src/runtime-cpp/out/telar-runtime \
  --lua-probe src/desktop-mode/out/debug/traffic_dbg
```

On 2026-10-30, both regression cases passed with the ordinary runtime and with
the AddressSanitizer runtime. A separate 100-connection diagnostic reproduced
observation loss while all binary relays completed exactly; this is not a
passing privileged domain-selection result.

Add `--domain-selection` to the privileged command to select `localhost` through
Lua and verify its resolved address snapshot forwards the binary connection.
On 2026-10-30, the user reported this focused privileged check passing: capture
start/stop, a real packet, DNS snapshot activation, native redirected binary
relay, acknowledged cleanup and direct connections after stop. This establishes
the exercised `localhost` selection. The separate routed-capture, virtual
interface lifecycle and native PID-selection checks were subsequently reported
passing on the same date. After an incoming-only timeout and the listener/NAT
address correction, the user reported incoming-only IPv4 forwarding passing,
including destination exclusion, half-closes, direct local-client connections
and cleanup. The separate combined IPv4 run subsequently passed incoming,
selected outgoing and local-client forwarding, exclusions and restoration of
direct connections and PF loopback state after shutdown.

On 2026-10-29, the user reported the privileged check passing on macOS: capture
start/stop, a real loopback packet, redirect activation, binary relay, acknowledged
cleanup and direct connections after stop. This does not establish VPN, incoming
flow selection, system-keychain changes or browser trust.

### Browser and user-keychain acceptance

`tools/check_browser_trust.py` separates preparation from an explicit OS-trust
change. Preparation generates private fixture authorities, validates a leaf
with evaluation-local anchors through macOS `security verify-cert`, proves that
the same chain is untrusted by default, and launches an installed Chromium
browser through the authenticated runtime proxy. The browser must reject the
private interception CA, and Desktop Lua must receive
`tls_client_handshake_failed`. Preparation does not install OS trust.

Use Python 3.10 or newer for the optional browser automation dependency. No
managed browser download is needed when Chrome, Chromium, Brave or Edge is
already installed; `--browser` can select its executable explicitly.

```sh
python3 -m venv /tmp/telar-browser-venv
/tmp/telar-browser-venv/bin/python -m pip install \
  -r src/runtime-cpp/tools/requirements-browser.txt
/tmp/telar-browser-venv/bin/python src/runtime-cpp/tools/check_browser_trust.py \
  --runtime src/runtime-cpp/out/telar-runtime \
  --lua-probe src/desktop-mode/out/debug/traffic_dbg \
  --tls-probe src/runtime-cpp/out/tls-tests
```

The default HTTPS origin is `https://example.com`; supply `--url` with a reachable
HTTPS origin whose certificate the runtime already trusts when needed. A failed
DNS lookup or origin handshake does not count as browser rejection of the CA.
The browser uses a fresh temporary profile, sandboxing, authenticated proxy
access and strict HTTPS certificate verification. The script disables
Playwright's mock-keychain launch argument. Authentication uses the private
runtime proxy secret in memory; it is not printed or added to the prepared state.
See [Playwright's authenticated proxy API](https://playwright.dev/python/docs/network#http-proxy).

Preparation prints the private diagnostic directory, the exact future system
CA's SHA-256 and a separate `--prepared ... --live --fingerprint ...` command.
Review that certificate before running the live command as the ordinary account.
This command changes that account's login keychain and can require macOS
authorization. It installs the reviewed CA through `traffic.ca.install`, checks
native trust and browser delivery of a Lua-rewritten HTTPS response, uninstalls
through `traffic.ca.uninstall`, and requires browser rejection again. It also
checks that a leaf signed by the retired CA is no longer trusted and that the
exact certificate is absent from the selected keychain. Thus switching the
runtime back to its private signer alone cannot satisfy removal acceptance.

Installation failures still attempt fingerprint-scoped removal even if no local
installation record was committed. Failed checks preserve their diagnostics and
any cleanup errors. `--prepared DIRECTORY --cleanup --fingerprint SHA256` retries
removal of only the prepared CA before deleting the fixture. Live checks reject
shared fixture files, mismatched certificates/fingerprints and a different target
keychain. They do not cover installed-CA rotation or browsers with private trust
stores.

On 2026-10-29, preparation and the explicitly authorized live phase passed with
the installed Chrome browser and `--url https://www.google.com`: native
anchored/untrusted chain checks, strict browser rejection, installation through
Desktop Lua, native user-keychain trust, browser delivery of a Lua-rewritten HTTPS
response, uninstall through Desktop Lua and browser rejection after removal.
The retired CA's leaf failed native trust validation, its exact certificate was
absent from the selected keychain, and the private fixture directory was removed.
The separate rotation/recovery check below extends this evidence to installed
authorities.

### Rotation and publication-failure recovery

`tools/check_ca_rotation.py` reuses the browser verifier and adds a deterministic
publication fault. Its preparation remains unprivileged and does not install
OS trust. It temporarily replaces only the fixture's `ca-active-cert.pem` with
a nonempty directory, requests private CA rotation through Desktop Lua and
requires the operation to fail with new TLS sessions suspended. Chrome must
fail and Lua must receive `tls_context_failed`. After restoring the exact
previous public file, retrying rotation must publish the new signer, resume TLS
and produce the expected browser rejection of an untrusted private CA.

```sh
/tmp/telar-browser-venv/bin/python src/runtime-cpp/tools/check_ca_rotation.py \
  --runtime src/runtime-cpp/out/telar-runtime \
  --lua-probe src/desktop-mode/out/debug/traffic_dbg \
  --tls-probe src/runtime-cpp/out/tls-tests \
  --url https://YOUR_REACHABLE_HTTPS_ORIGIN
```

Preparation prints the initial CA's fingerprint and a separate explicit live
command. The live phase installs that reviewed initial authority, performs a
successful installed-CA rotation and then a second rotation whose publication
is deliberately blocked. It verifies native trust and Chrome HTTPS rewriting
before and after normal rotation, rejects retired authorities, proves new TLS
is suspended during the publication failure, and repairs synchronization by
retrying installation of the already-persisted replacement. A fresh Chrome
session must then receive the Lua-rewritten HTTPS response. Final uninstall
must retire all three authorities and return the browser to certificate
rejection. The two rotated roots are generated by the actual runtime rather
than substituted by the test.

Public candidate certificates are retained in a bounded fixture archive while
each operation runs. Cleanup removes only these known certificates/trust
settings, verifies every available retired leaf and checks each archived root
with the native basic policy without an explicit anchor. A pre-operation
keychain fingerprint baseline detects additional unaccounted certificates.
Such certificates are reported in private diagnostics and are not deleted.
An existing baseline prevents restarting a failed native attempt and silently
adopting its remaining certificates as preexisting state.

Failed runs preserve their private fixture and reviewed initial certificate.
Use the same script with `--prepared DIRECTORY --cleanup --fingerprint SHA256`
to retry cleanup; this validates the reviewed certificate even after canonical
CA files have rotated. Private publication failure/recovery and the eight
verifier guard/cleanup cases passed on 2026-10-30.

On 2026-10-30, the explicitly authorized installed-CA phase also passed with
the installed Chrome browser. It verified initial installation, successful
rotation with continued Lua-rewritten HTTPS delivery, native rejection of the
retired authority, and a second rotation with publication deliberately blocked.
New TLS sessions failed with `tls_context_failed` while the signer was suspended.
Retrying installation adopted the persisted replacement and restored rewritten
HTTPS delivery. Final uninstall rejected all three authorities under native
trust evaluation, removed their exact certificates and restored browser
certificate rejection. Cleanup restored the pre-operation keychain certificate
fingerprint baseline and removed the fixture; an independent read-only check
confirmed both results. The chosen fault occurs after store replacement;
partial OS trust-command rollback remains covered by injected-command tests,
not by this native publication-failure scenario.
