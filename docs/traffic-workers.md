# Persistent runtime Lua traffic apps

Configured plugin packages can run traffic callbacks in isolated C++-hosted Lua
workers. Their lifetime belongs to the runtime: closing Desktop does not remove
their subscriptions, rules or Lua state. Networking, CA keys and forwarding stay
in the native services. Lua never runs in a privileged helper.

## Package and grants

Create a normal plugin package with a `plugin.json` manifest:

```json
{
  "api_version": 1,
  "id": "my-traffic-app",
  "version": "1",
  "entry": "main.lua",
  "source": {"url": "local", "revision": "1"},
  "capabilities": ["traffic.observe", "traffic.intercept"]
}
```

`traffic.observe` permits packet, UDP/ICMP datagram, reconstructed/forwarded flow and completed HTTP
subscriptions. `traffic.intercept` permits scoped stream and structured HTTP
decisions. Declaring a capability does not grant it. Native startup checks both
the manifest and the user's digest-bound grant. Modifying a package invalidates
that grant for subsequent startup. Existing workers and their restarts use a
verified private package snapshot, so editing the original source cannot replace
code that is already authorized.

Two independent capabilities expose the control API:

- `traffic.control` permits capture/redirect and CA mutations, subject to the
  runtime's `network_control` grant and native helper authorization.
- `traffic.record` permits bounded recording creation, queries and export within
  the package's own namespace. It does not grant live subscriptions or mutations.

Every granted traffic capability can read native status and the public CA
certificate. No capability exposes the CA private key. Neither control permission
implicitly grants interception, nor recording permission administration.

```sh
telar plugin inspect /absolute/path/my-traffic-app
telar plugin trust /absolute/path/my-traffic-app --capability traffic.observe
# Explicitly grant interception when wanted:
telar plugin trust /absolute/path/my-traffic-app \
  --capability traffic.observe --capability traffic.intercept
# Revoke by ID, even if the original directory has changed or disappeared:
telar plugin untrust my-traffic-app
```

Configure the package and the global traffic capabilities:

```lua
return {
  api_version = 2,
  plugins = {{path = "./my-traffic-app"}},
  runtime = {
    proxy = {
      enabled = true,
      network_capture = true,
      stream_interception = true,
      intercept_hosts = {"*.example.test"},
      capture = {enabled = true},
    },
  },
}
```

`stream_interception` still gates mutations globally. Capture and redirection
activation remain [separate administrative operations](traffic-control.md).
Packages and configuration are loaded at runtime startup. A native monitor checks
the private trust store every 250 ms, independently of forwarding. Removing any
previously effective capability, replacing its digest, or revoking its ID cancels
the entire affected worker and unregisters its hooks. Other packages continue.
Pending decisions use their declared disconnect policy; removing the app also
removes its rules from future traffic. This applies to workers disabled by
repeated crashes as well. Missing, unsafe or invalid trust files revoke all
running package grants. Queued notification effects from revoked workers are
discarded. Cancellation interrupts a worker waiting for a Lua reply.

Adding grants never starts or resumes a package automatically. Restart the runtime
to load new packages, apply configuration or resume a previously revoked package.
App management from Desktop and runtime configuration reload remain pending.

## Control and recording callbacks

Workers use the same asynchronous [control](traffic-control.md) and
[recording](traffic-recordings.md) methods as Desktop:

```lua
local traffic = require("telar.traffic")

traffic.status(function(err, reply)
  assert(not err, err)
  -- administration_enabled includes both global and package authorization.
end)

-- Requires traffic.control and proxy.network_control:
traffic.capture.start(function(err, reply)
  assert(not err, err)
  -- Inspect reply.result, including authorization_required.
end)

-- Requires traffic.record. Resume a runtime-owned session after a VM restart:
traffic.recordings.list(function(err, reply)
  assert(not err, err)
  assert(reply.result == "ok", reply.message)
  if #reply.recordings == 0 then
    traffic.recordings.start({
      events = {packet = true},
      max_bytes = 1024 * 1024,
      max_events = 1024,
    }, function(err, reply) end)
  else
    traffic.recordings.query({id = reply.recordings[1].id}, function(err, reply)
      assert(not err, err)
      assert(reply.result == "ok", reply.message)
      -- Binary packet/datagram/flow/HTTP DTOs and cursor metadata, as in Desktop.
    end)
  end
end)
```

Each operation holds one callback and returns a cancellation function. A package
can have at most eight outstanding control requests, within its 32-registration
limit. Requests and replies are bounded, with a 45-second transport deadline.
Transport failures reach that callback and do not restart unrelated hooks.
Control callbacks can answer a still-pending stream/HTTP event through its retained
responder. The original interception deadline continues to apply.

The native parent and the control service validate the declared and granted
capability independently. Native socket attachments carry the package identity,
digest and a revocable authorization lease; Lua supplies none of those fields.
Revocation also invalidates an already-open native control channel. An accepted
administrative change can finish after callback cancellation or revocation; it is
not rolled back. New commands are denied once their lease is revoked.

Recordings belong to the package ID and digest, independently of the child VM.
Listing, reading, stopping, deleting or exporting another package's recording is
denied even if its numeric ID is known. A worker restart can list its existing
recordings. Revocation stops that package's recordings and unregisters its hooks;
retained rows remain available to the trusted account-level Desktop client until
expiry/removal. They still consume the runtime's bounded recording budget.

An in-flight control reply from an old VM is never delivered to a restarted VM.
The new entrypoint may issue new commands; apps should list/reuse recordings and
handle operations that were accepted before their previous callback disappeared.

## Callbacks

`main.lua` uses the same traffic API implementation as Desktop:

```lua
local traffic = require("telar.traffic")

local stop_packets = traffic.subscribe({
  events = {packet = true},
  filter = "tcp port 443",
}, function(err, event)
  assert(not err, err)
  if event.kind == "packet" then
    -- Binary event.bytes, interface identity, original size and loss counters.
  end
end)

local stop_http = traffic.intercept({
  stage = "http",
  host = "*.example.test",
  failure = "allow",
  timeout_ms = 2000,
}, function(err, event)
  assert(not err, err)
  if event.kind ~= "http.intercept.request" then return end
  if event.message.response then return {action = "allow"} end
  return {action = "replace", body = event.message.body .. "\0suffix"}
end)

return {}
```

Traffic-only packages need no `on_exchange` handler. A package can still implement
the legacy handler when it also declares and receives `proxy.tap`. One worker/VM
holds a package's traffic and legacy exchange state. Observer callbacks may return
notification effects; delivery also requires the `notifications` capability.

Every traffic callback receives `event.app` with the native package ID, digest
and configuration generation. These values are metadata, not credentials supplied
by the Lua app. Registrations can be cancelled or created during callbacks.
`event.respond` can be retained and called during a later callback, before the
runtime's deadline. Cancellation makes that responder inactive. Callbacks run
serially within one package; other packages and the proxy have their own workers.

The [message/stream limits and failure policies](traffic-flows.md) apply. The
runtime repairs HTTP framing and content coding. Matching runtime package handlers
run in configured package order, then registration order within the package.
Desktop-owned handlers follow the configured package handlers. A pending message
keeps its original handler snapshot; a newly registered rule does not acquire it.

## Ownership and failures

The native runtime creates a separate private channel for each package
registration. It binds that channel to the verified digest, grants and generation
before accepting a role or rule. An observation-only package cannot use its
channel to intercept or become a capture producer. Lua cannot select an identity,
open these channels, execute processes or access raw filesystem/network APIs.

Workers reuse the plugin sandbox: 64 MiB of Lua memory, five million instructions
and a two-second callback budget, with bounded queues, frames and replies. A
package can hold at most 32 registrations and queue at most 32 decisions per
callback, subject to a 3 MiB aggregate decision limit. The account-level limits on
subscriptions/controllers still apply across packages and Desktop clients.

A callback error resolves its current decision using the declared failure policy
and emits a bounded `flow.error` with `app_callback_error:PACKAGE_ID`. Earlier
apps' replacements survive an allow failure. Those observations remain subject to
subscriber loss counters. A worker crash suspends its native controllers while
the VM restarts. Existing decisions fail according to policy; future matching
traffic also follows that policy. A fail-closed rule cannot silently disappear
while its worker is unavailable.

On successful restart, retained controllers receive a new internal generation;
expired decisions and old pending steps cannot be answered by the new VM.
Retained registrations receive `ready` with reason `worker_restarted`. Runtime
Lua state is reset after a worker crash, and registrations are rebuilt from the
verified entrypoint. Repeated crashes disable the worker after the existing
bounded restart window; its failure policy remains in force until shutdown or
explicit permission revocation. A transport failure can require rebuilding
the package's channels. Closing Desktop does not trigger any of this recovery.

## Verification

```sh
cmake --build services/runtime-cpp/out --target telar-runtime plugin-traffic-tests plugin-tests traffic-flow-tests
ctest --test-dir services/runtime-cpp/out -R '^(plugin-traffic-tests|plugin-tests|traffic-flow-tests)$' --output-on-failure
python3 services/runtime-cpp/tools/check_traffic_workers.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg
```

The real-runtime check grants packages through the CLI and uses real TCP origins.
It verifies native BPF filtering, packet/HTTP state sharing, digest attribution,
ordered binary/gzip edits, callback failure, Desktop disconnect, dynamic
cancellation, rejection of stale responders, recovery from a verified snapshot,
isolation between workers, fail-closed behavior when a crashed worker cannot
reload, live capability reduction and revocation, cancellation of disabled apps,
and denial after trust-store corruption. It uses isolated trust/configuration
files and needs no sudo.

`tools/check_traffic_app_control.py` additionally runs actual recorder/admin
packages. It verifies native permission denial, private CA rotation, concurrent
control requests, asynchronous HTTP decisions, cross-package recording denial,
recording recovery after a worker crash and stopping records on revocation while
another app continues. It does not install OS trust or require sudo.
