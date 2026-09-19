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

`telar workspace get ID [--json]` selects one exact entry from that same
snapshot. `--current` resolves `TELAR_WORKSPACE_ID`; missing or invalid context
fails before connecting. An absent workspace fails with no partial JSON output.

`telar workspace create --directory PATH [--name NAME]` validates and resolves
an existing directory before connecting, then uses `create_workspace` with a
shell launch. The default name is the directory basename. It never runs Git
unless `--worktree` is supplied. Existing worktree creation keeps its original
behavior. The socket test uses a temporary directory without a Git repository.

`telar workspace rename ID NAME [--json]` sends `rename_workspace` and waits
for the matching request ID in `workspace_snapshot`. It reports the canonical
name from that response. Unrelated events cannot acknowledge the mutation.
`Session.exchange` owns a bounded send buffer and correlates typed replies;
the socket test deliberately interleaves an unrelated response.

## Tabs

`telar tab list [--workspace ID] [--json]` requests `workspace_snapshot` and
prints stable tab IDs, zero-based positions, pane counts and labels in runtime
order. Without `--workspace`, it requires `TELAR_WORKSPACE_ID`. It never
attaches or selects a pane. The contract test uses tab IDs whose numeric order
differs from their positions.

`telar tab get ID [--workspace ID] [--json]` requests `tab_snapshot` and returns
the tab's panel identities, generations, kinds and lifecycle states. `--current`
resolves `TELAR_TAB_ID`. A mismatched workspace or tab in the response fails;
querying never obtains a geometry lease or attaches to a terminal.

`telar tab rename ID LABEL [--workspace ID] [--json]` validates a bounded UTF-8
label, sends `rename_tab` and reports the label acknowledged by `tab_renamed`.
The reply must match both the request ID and the complete tab location.

`telar tab close ID [--workspace ID] [--json]` sends `close_tab` and waits for
`tab_closed`. JSON reports whether closing the final tab also retired its
workspace. `TabControl` owns request construction and response validation for
operations on an existing tab; CLI assembly only resolves the target and I/O.

`telar tab move ID previous|next [--relative-to ID] [--workspace ID] [--json]`
sends `move_tab`. Without an anchor it moves one position; with an anchor it
inserts before or after that tab. Output reports the absolute zero-based
position confirmed by `tab_moved`, including a successful no-op at an edge.

## Managed agents

`telar agent interrupt TARGET [--json]` resolves an agent ID, unique title or
`--current` through the existing agent snapshot, then sends `agent_interrupt`
with the exact pane generation. It waits for the correlated acceptance; this
means the runtime admitted the interrupt, not that provider shutdown completed.
Terminal panes and stale generations retain the runtime's explicit rejection.
The socket test asserts the generation and acknowledgement boundary.

`telar agent thread TARGET [--json]` sends `query_agent_thread`, waits for
acceptance and copies the exact pane generation's `agent_thread_snapshot` into
bounded owned storage. Output preserves item identities, parent relationships,
provider references, phases, fragment boundaries, tool lifecycle and pending
approval details. A truncation flag distinguishes a retained window from a
complete transcript. No terminal text scraping or UI attachment is involved.

`telar agent models TARGET [--json]` reads the native thread catalog and reports
the selected model, effort and access alongside provider-advertised model IDs,
labels, supported efforts and defaults. Effort identifiers are not hardcoded.

`telar agent skills TARGET [--json]` reports the provider skill catalog with
revision, loading/ready/failed phase, truncation, names, labels, descriptions
and scopes. Empty/loading catalogs are not reported as a successful discovery.

`telar agent conversations TARGET [--json]` lists stable provider conversation
IDs and titles, catalog phase, whether more entries exist and whether this
pane can resume a conversation. It does not expose unstable catalog indices.
