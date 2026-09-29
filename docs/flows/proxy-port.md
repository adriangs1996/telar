# Proxy port

The runtime owns the loopback port its proxy listens on. Every pane child
inherits it in `HTTPS_PROXY`, and a daemon a pane started (Codex's
`app-server`, a language server) keeps it after the pane and the runtime are
gone. The port therefore has to survive a restart of the same runtime and must
not move to another runtime that shares the proxy directory.

## Trigger

A runtime starts with `runtime.proxy.enabled`.

## End-to-end path

```text
ServerLaunch.prepareRuntimeStorage
  PortMemory.path(proxy_directory, endpoint)   proxy-port-<digest of the socket path>
  Config.port_path, Config.legacy_port_path    legacy: the shared proxy-port
        |
Proxy.create -> Service.create
  PortMemory.load        own port, shared legacy port, ports other runtimes remember
  Listener.bind          own (or legacy) first; then free ports nobody remembers;
                         then any free port in 45100..45227
    bindPort             plain bind; if the port is in use and nothing answers
                         a connection there, bind again with SO_REUSEADDR
  PortMemory.remember    write own file; retire legacy once bound onto it;
                         forget another runtime's file that named the bound port
  Service.preferred_port the port it tried first
        |
Proxy.port / Proxy.preferredPort -> ProxyRuntime.port / preferredPort
  client_delivery.sources -> Delivery: proxy_status { port, preferred_port }
      -> telar runtime status: "Proxy port: ..." with a warning when they differ
  runtime_telemetry.sample -> "proxy_port", "proxy_preferred_port" in each line
```

## Rules

- The key is the first 8 bytes of the SHA-256 of the endpoint path, in hex. The
  same socket always maps to the same file; the path is not canonicalized, so
  a runtime reached through a different spelling of its socket path is a
  different runtime.
- A port file holds one decimal port. A value outside the range, or anything
  else, is forgotten. A lost or corrupt file costs only the preference.
- The scan looks at no more than 4096 directory entries and only at regular
  files named `proxy-port-` plus 16 lowercase hex digits. Writes go through
  `ca.writeSecure` (atomic, mode 0600) in the owner-only proxy directory.
- A port counts as free when only TIME_WAIT connections hold it. Stopping the
  runtime closes its children's connections from the proxy's side, so without
  this a restart within a minute would move to another port. The connection
  probe runs before `SO_REUSEADDR` because on BSD that option binds loopback
  over another process's wildcard listener. `SO_REUSEPORT` is never set.
  Windows keeps the plain bind.
- Binding a port another runtime remembers deletes that runtime's file, so the
  directory holds at most one file per port, 128 in all.
- The shared `proxy-port` of earlier versions is a preference only for a
  runtime without a file of its own. Once a runtime has its own file, the
  shared port counts as another runtime's.
- The secret stays one per directory; see
  [ProxyTLS](../proxy-tls.md#traffic-path-and-trust).

## Failure policy

Every file operation is best effort: the proxy runs on the port it bound
whatever happens to its memory. A preferred port held by another process
does not stop the start. The runtime binds another, remembers it, and reports
both ports, so `telar runtime status` names the port that processes started
earlier may still point at. Exhausting the range fails the start with
`error.ProxyPortUnavailable`, as before.

## Validation

- `src/backend/proxy/service/PortMemory.zig` proves one file per endpoint,
  foreign values, migration from the shared file only on a successful bind,
  the shared port reserved once a runtime has its own, and forgetting the
  claim of a runtime that lost its port.
- `src/backend/proxy/service/listener_support.zig` proves the listener leaves
  remembered ports until nothing else is free, gets its port back while its
  closed connections are in TIME_WAIT, and never shadows a wildcard listener.
- `src/core/schema_contract_test.zig` fixes the wire bytes of `proxy_status`
  and rejects a preferred port without a bound one;
  `src/cli/runtime.zig` covers the status text and its warning;
  `src/backend/runtime/observability/telemetry.zig` covers the log fields.
