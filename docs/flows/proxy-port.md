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
  runtime_connection.defaultEndpoint           is this the default socket?
  Config.port_path, Config.endpoint
  Config.legacy_port_path                      the shared proxy-port, default socket only
        |
Proxy.create -> Service.create
  PortMemory.load        own port, shared legacy port, ports other runtimes
                         remember; removes files whose socket directory is gone
  Listener.bind          own (or legacy) first; then free ports nobody remembers;
                         then any free port in 45100..45227
    bindPort             Linux: SO_REUSEADDR always
                         BSD: plain bind; for the preferred port, when refused
                         and a 50 ms probe is refused too, SO_REUSEADDR
  PortMemory.remember    write "<port>\n<endpoint>\n"; if that worked, retire
                         legacy once bound onto it and forget another runtime's
                         file that named the bound port
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
- A port file holds one decimal port and, on the next line, the socket path
  of the runtime that wrote it. A port outside the range, or anything else,
  is forgotten. A lost or corrupt file costs only the preference.
- A start removes another runtime's file when the directory of its recorded
  socket no longer exists: that runtime cannot come back at that path. Any
  other failure to look keeps the file. A reboot can empty a temporary socket
  directory and so drop the file of a runtime that will come back there; no
  process that inherited its port survives the reboot, so only the preference
  is lost.
- The proxy directory may be relative when `HOME` is: files are then opened
  relative to the working directory, and nothing is written, since atomic
  writes need an absolute path. A relative `XDG_DATA_HOME` is ignored.
- The scan looks at no more than 4096 directory entries and only at regular
  files named `proxy-port-` plus 16 lowercase hex digits. Writes go through
  `ca.writeSecure` (atomic, mode 0600) in the owner-only proxy directory.
- A port counts as free when only TIME_WAIT connections hold it. Stopping the
  runtime closes its children's connections from the proxy's side, so without
  this a restart within a minute would move to another port. Linux sets
  `SO_REUSEADDR` on every listener, because a TIME_WAIT connection there
  yields only when the listener that accepted it set the option too, and the
  option never binds over a listening socket. BSD probes before
  `SO_REUSEADDR`, because there the option binds loopback over another
  process's wildcard listener; the probe is non-blocking with a 50 ms limit,
  since a bound port without a listener or a full backlog leaves a blocking
  connect waiting for about eight seconds on macOS. Only the preferred port is
  probed, so a start waits at most one probe. `SO_REUSEPORT` is never set.
  Windows keeps the plain bind.
- Binding a port another runtime remembers deletes that runtime's file, so the
  directory holds at most one file per port, 128 in all.
- The shared `proxy-port` of earlier versions is a preference only for the
  runtime on the default socket, and only while it has no file of its own.
  Once it has one, the shared port counts as another runtime's. A runtime on
  any other socket never reads it, so it reports no displaced port for it.
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
  foreign values, migration from the shared file by the default socket alone
  and only on a successful bind and write, the shared port reserved once a
  runtime has its own, forgetting the claim of a runtime that lost its port,
  removing the file of a runtime whose socket directory is gone, and a
  relative directory that neither crashes nor writes.
- `src/backend/proxy/service/listener_support.zig` proves the listener leaves
  remembered ports until nothing else is free, gets its port back while its
  closed connections are in TIME_WAIT, never shadows a wildcard listener, and
  gives up on a silent preferred port within the probe's limit. The suite runs
  on macOS and on Linux (`zig build test-backend-proxy -Dgui=false`).
- `src/client/machines/runtime_connection.zig` proves the default endpoint
  ignores the sockets a pane or a user names; `src/cli/server.zig` proves a
  relative `XDG_DATA_HOME` is ignored.
- `src/core/schema_contract_test.zig` fixes the wire bytes of `proxy_status`
  and rejects a preferred port without a bound one;
  `src/cli/runtime.zig` covers the status text and its warning;
  `src/backend/runtime/observability/telemetry.zig` covers the log fields.
