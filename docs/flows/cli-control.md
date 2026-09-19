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

`telar agent approvals TARGET [--json]` returns the pending approval identity,
kind and description, or an empty array. Querying never answers the approval.

`telar agent approve TARGET APPROVAL_ID [--json]` sends an explicit positive
approval decision with the observed pane generation and waits for runtime
admission. The provider remains responsible for rejecting stale approval IDs.

`telar agent reject TARGET APPROVAL_ID [--json]` sends the negative decision
through the same generation-checked path. `accepted` in CLI output means the
runtime admitted the command, not that the user approved the provider action.

`telar agent prompt TARGET TEXT` resolves the exact pane kind through its tab
snapshot. Managed panes receive `agent_prompt` with their live model, effort
and access selection; terminal agents retain `send_pane_text`. A missing or
changed generation fails before submission, with no fallback or duplicate send.

`agent prompt --image /absolute/path.png` accepts up to four image paths using
the existing protocol validator. An empty text argument supports image-only
submissions. Paths refer to the runtime machine; the provider performs image
loading. Terminal panes reject image submissions before sending any text.

`agent prompt --model ID --effort ID --access MODE` validates model/effort
against the live catalog before submission. Selecting a model uses its default
effort unless overridden; omitted options retain the current selection. Access
is `read_only`, `workspace` or `full_access`. Terminal panes reject these flags.

`telar agent clear TARGET [--json]` submits the existing native `/clear`
conversation command with current provider options. It starts a new conversation
in that pane; it does not erase history or restart the pane process. Output
acknowledges admission; provider completion remains asynchronous.

`telar agent rename TARGET TITLE [--json]` validates the existing bounded title
contract and submits native `/rename`. This renames the provider conversation;
reporting a sidebar title is a separate operation.

`telar agent history TARGET [--cursor TOKEN | --anchor ID --anchor-turn ID]
[--direction older|newer] [--json]` reads one correlated provider page. JSON
includes opaque before/after cursors and availability flags alongside structured
thread data. A request cannot mix a cursor with an item/turn anchor. The pane
and view generations are checked before output; reading does not alter live state.

`telar agent watch TARGET [--jsonl] [--count N]` streams the initial native
thread and later runtime revisions as JSON Lines. It filters other panes, stale
generations and duplicate revisions; updates may be coalesced by the runtime.
There is no polling or idle timeout. Removal and resync require an explicit
restart; runtime shutdown ends the stream. Each record flushes immediately.

`telar agent report-title TARGET TITLE [--json]` reports the agent-owned title
to the runtime; an empty title clears the report. `--current` uses both pane
ID and generation from the environment so initial reports need no prior agent
discovery. Other targets resolve through the agent snapshot.

`telar agent report-state TARGET STATE` exposes official lifecycle reports:
working, blocked, ready, exited and settling. Optional flags preserve blocked
reason, event text, session ID and session file kind/path. The shared wire
validator rejects invalid state/reason combinations before any report is sent.

`telar agent report-command TARGET started|finished COMMAND --provider NAME`
reports a shell-tool observation without executing it. Optional `--tool-call`,
`--cwd`, `--session` and `--exit-code` preserve its correlation and outcome. A
started report cannot carry an exit code; provider and command are required.

`telar agent acknowledge TARGET [--json]` sends the exact generation seen marker,
then queries agent state on the same ordered connection. It returns the observed
state only after the marker was processed; a stale generation or unchanged done
state fails. It does not approve pending tools or send input.

`telar agent resume TARGET CONVERSATION_ID [--json]` resolves a stable ID in the
current native catalog and requires an unused, ready conversation. The request
pins the snapshot revision; runtime authority rejects changed state before
reserving the provider conversation. UI resume sends the same precondition.
This changes the wire schema to generation 59 with a new golden fingerprint.
The control remains bounded and allocation-free in the runtime request path;
CLI snapshot storage is bounded and released on every outcome. Handler tests
cover stale revisions, stale pane generations and duplicate open conversations.

Validation: CLI socket contracts and `test-runtime`, `test-wire`, `test-client`,
`test-gui` pass. The broad `test-schema` command also includes PTY transport
integration; that separate run stalled and was terminated. No transport pass
is claimed. Provider startup now honors the supplied runtime PATH, which
restores the existing managed-checkpoint regression test on Zig 0.16.

## Pane topology

`telar pane list [--workspace ID [--tab ID]] [--json]` walks workspace and tab
snapshots and lists every terminal and managed pane with its location, position,
generation, kind and lifecycle. Queries attach to no PTY and start no runtime.
The catalog owns copied IDs before issuing another request and is bounded by
the runtime pane limit. Concurrent removal fails explicitly; this is not an
atomic cross-workspace snapshot. Output begins only after enumeration succeeds.

`telar pane get ID|--current [--workspace ID [--tab ID]] [--json]` selects one
entry from the same topology catalog, including terminals without an observed
agent. It prints one object with a zero-based position, or exits 2 without
partial output when absent. Explicit tab scope avoids full-runtime enumeration.

## Command assistance

`telar command suggest PANE|--current TEXT [--json]` asks the runtime engine
for one command using that pane’s existing cwd/screen context. It only prints
the suggestion. Ready exits 0, timeout exits 3, unavailable/failed exit 1; JSON
preserves the explicit status. No terminal input follows the suggestion reply.
