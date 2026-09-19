# CLI control

CLI control commands reuse the runtime's typed protocol. Read-only commands
attach to an existing runtime and never launch a pane or start a server.
`Session` owns the connection and bounded receive buffer; decoded response
slices expire on the next receive. Runtime subscriptions use a fresh nonzero
identity and never overwrite a UI client's retained layout.

The CLI runs on the observation path. It has the same local account authority
as existing CLI commands. Disconnect retires its subscription. Runtime failure
and malformed messages fail the command rather than returning partial success.

## Runtime status

`telar runtime status [--json] [--socket PATH]` connects through
`RuntimeConnector`, sends `request_runtime_state`, and prints the returned
`proxy_status` together with the negotiated schema version. A successful
handshake establishes that the runtime is running. Status does not claim that
a disabled proxy is active or that an uninstalled CA is trusted.

Parser and JSON tests run under `zig build test-cli`. The socket contract and
absence of auto-start are exercised by `python3 tools/test_cli_control.py`
after `zig build`. These tests never connect to the user's runtime.
