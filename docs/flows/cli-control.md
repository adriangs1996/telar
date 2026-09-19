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

## Runtime watch

`telar runtime watch [--jsonl] [--count N]` streams global projections as JSON
lines, flushing each event before waiting again. It retains no event history
and does no polling. `--count` bounds the number of emitted events. Runtime
shutdown emits a final event and exits successfully; a resync notice emits
the notice and fails explicitly, allowing the caller to reconnect for a fresh
snapshot. Closing the process closes its subscription. Idle streams have no
timeout; finite status queries have a 30-second receive deadline.

## Runtime metrics

`telar runtime metrics [--json]` waits for the runtime's sampled
`system_metrics`, ignoring unrelated initial snapshots. JSON retains the
protocol's integer tenths-of-GiB memory unit and reports a missing battery as
`null`. Text output converts memory to GiB with one decimal. The socket test
verifies ordering, units, and absent-battery behavior.

## Workspace list

`telar workspace list [--json]` reads the first `workspace_list` subscription
snapshot and disconnects. Each row includes the stable ID, name, directory,
tab count, branch and dirty flag. Git metadata is the runtime's retained probe;
the CLI does not invoke Git. JSON is an array, including `[]` for an empty
runtime. The socket test checks interleaved events and escaped labels.
