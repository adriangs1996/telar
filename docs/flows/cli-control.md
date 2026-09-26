# CLI control

CLI control commands reuse the runtime's typed protocol. New inspection entrypoints and
routed client commands connect to an existing runtime and never start a server.
Legacy `agent list/get/wait/prompt/read/report-session` and `pane read/send-keys`
retain their existing startup behavior.
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
the tab's panel identities, generations and lifecycle states. `--current`
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

## Agents

`telar agent prompt TARGET TEXT` types the prompt into the agent's pane through
`send_pane_text`, pinned to the exact pane generation. A missing or changed
generation fails before submission, with no fallback or duplicate send.

`telar agent report-title TARGET TITLE [--json]` reports the agent-owned title
to the runtime; an empty title clears the report. `--current` uses both pane
ID and generation from the environment so initial reports need no prior agent
discovery. Other targets resolve through the agent snapshot.

`telar agent report-state TARGET STATE` exposes official lifecycle reports:
working, blocked, ready, exited, settling, continuing, waiting, idle and released. Optional flags preserve blocked
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

## Pane topology

`telar pane list [--workspace ID [--tab ID]] [--json]` walks workspace and tab
snapshots and lists every pane with its location, position, generation and
lifecycle. Queries attach to no PTY and start no runtime.
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

## Interactive clients

`telar client list [--json]` queries active UI connections with their exact
connection generation, retained identity, attachment count and last input pane.
The bounded catalog copies at most eight records and performs no allocation
or I/O in the runtime handler. CLI runtime subscriptions explicitly declare
themselves noninteractive so observers cannot be selected as visual clients.
The wire schema is now generation 60. Unknown counts and invalid identities
are rejected by the codec; the golden corpus includes discovery and reply.

`telar client get ID [--json]` returns one live interactive connection from
the same bounded catalog. An absent connection exits 2 with empty stdout.

`telar client detach ID [--json]` resolves the current connection generation,
then requests its teardown. The runtime accepts only a separate control caller
and an exact live UI generation. The existing teardown shuts its connection,
releases attachments and geometry, and leaves runtime-owned processes alive.
The handler validates before effects; stale generations and observers are
covered by tests. Schema generation 61 adds the bounded teardown request.

`workspace select ID --client ID` discovers a live UI connection and routes to
its exact generation. The UI uses the existing workspace selection/handoff
controller. An already selected workspace returns `applied`; asynchronous
handoff admission returns `admitted`, not a claim of completed attachment.
Unknown workspaces, busy clients and disconnects fail explicitly. The runtime
retains no presentation state from these commands. A session owns at most one
pending command; completion must match the sender generation, request, action
and target. Command and response text own at most 4096 UTF-8 bytes; queueing
never borrows decoder storage. Socket contracts cover success, UI rejection and
incorrect completion generations; runtime tests cover admission, ownership and
stale/unrelated completions. Protocol generation is 63.

`tab create --client ID [--label TEXT]` uses the selected client’s existing tab
creation gate, launch configuration and workspace geometry. It returns admission
after queuing creation; the runtime still confirms the new tab asynchronously.
Labels preserve UTF-8. A busy or unattached client fails without claiming creation.

`tab select ID --client ID` selects a tab in that client’s current workspace.
Already selected tabs return `applied`; changes return `admitted` while pane
attachment/snapshot synchronization proceeds. Unknown tabs or blocked selection fail.

`tab next --client ID` uses the existing cyclic tab selection policy. A single
tab is a successful no-op; absent tabs and pending snapshot gates fail explicitly.

`tab previous --client ID` uses the existing cyclic tab selection policy. A single
tab is a successful no-op; absent tabs and pending snapshot gates fail explicitly.

`pane create --client ID` creates a terminal pane by splitting the focused pane
horizontally, using the client’s launch settings and geometry. Admission fails
when the pane is unattached, a launch is pending, or the available area cannot
fit another pane. Runtime creation and its layout confirmation remain asynchronous.

`pane split ID horizontal|vertical --client ID` focuses the named pane in the
client’s active tab and requests its split. Horizontal means left/right; vertical
means top/bottom. The source must exist in that tab. Focus can change even when
creation is subsequently rejected by layout or launch admission. The split uses
the existing provisional-resize rollback and asynchronous creation confirmation.

`pane close`: Focuses an existing pane in the active tab and requests closure through the
attachment/operation gate. `admitted` means the close request is queued; pane
exit remains runtime authority. Focus remains changed if closure is unavailable.

`pane focus`: Focuses an existing pane in the selected client’s active tab. An already focused
pane is a successful no-op. Missing panes fail. The existing `pane focus
--current --direction DIRECTION` command retains its original routing behavior.

`pane resize`: Focuses the source pane and moves its nearest matching split edge by Telar’s
existing resize step. Constrained or absent split edges fail explicitly. The
geometry handler updates both local layout and runtime pane sizes.

`pane fullscreen`: Focuses the source pane and toggles fullscreen through the existing geometry
handler. The result value is 1 when fullscreen is enabled and 0 otherwise.

`pane scroll`: Changes the named pane’s client-owned scroll offset by a signed delta, without
changing focus or sending terminal keystrokes. Terminal viewport offsets and
native transcript offsets use their existing bounds; boundary no-ops succeed.
An unattached pane or active copy mode rejects the operation.

`sidebar get`: Returns the selected client’s committed sidebar visibility and preferred width.

`sidebar show`: Shows the sidebar idempotently and synchronizes pane geometry through the existing controller.

`sidebar hide`: Hides the sidebar idempotently and synchronizes pane geometry through the existing controller.

`sidebar resize 40`: Requests an exact sidebar width. Existing host-width and minimum-width bounds
apply, and the returned value reports the width actually committed.

`workspace-list expand`: Expands the workspace list idempotently in client model and host chrome.

`workspace-list collapse`: Collapses the workspace list idempotently in client model and host chrome.

`client open goto`: Opens the existing goto selector through its prompt admission controller.

`client open history`: Opens the history palette and queues its initial query. Result delivery remains asynchronous.

`client copy-mode`: Enters terminal copy mode through shared admission.
An already active copy mode is a successful no-op; unsupported or blocked panes fail.

`notification dismiss 5`: Dismisses one current notification and rearms its expiration timer. Missing identities fail.

`client open-link https://example.com`: Validates and routes a link through existing file/tab and host-opener policy.
Success means the bounded link-opening worker job or tab request was admitted.

`client clipboard copy copied ü`: Queues bounded UTF-8 text as a clipboard write on the selected client's
`model.to_host`. The host may complete the clipboard write asynchronously, so the CLI reports admission.

`pane copy` requests an inclusive terminal text selection in absolute history
coordinates and delivers it to the selected client’s clipboard. It uses the
runtime’s existing selection size/availability checks. Success means admission;
extraction and host clipboard delivery complete asynchronously. Native agent
text is available through `agent thread`/`agent history` and `client clipboard copy`.

`layout get --client ID` exports the active tab’s full split tree, ratios, pane
surfaces, focused pane and fullscreen state as a bounded hexadecimal token.
The token uses Telar’s validated layout schema and stable runtime identities;
it is intended for `layout apply` against the same live tab and pane membership.

`layout apply TOKEN --client ID` restores the active tab’s split tree, pane
surfaces, focus and fullscreen state. It rejects other tabs, changed pane sets,
invalid trees and in-flight client operations before model mutation. Existing
focus/geometry delivery synchronizes graphics and runtime sizes after commit.
Sidebar and workspace-list preferences remain controlled by their own commands.

`pane search ID TEXT` reads retained terminal history without attaching a UI.
The runtime captures the current pane generation at admission and preserves
the existing bounded row turns and search deadline. UI requests still require
attachment authority. Results contain absolute history coordinates and an
explicit truncation flag; generation changes, deadlines and missing panes fail.

`pane watch` emits changed text snapshots as JSON Lines by polling the existing
read API, every 250 ms by default (10..60000 ms configurable). It is not a raw
PTY byte stream: intermediate changes between polls may be coalesced. Topology
is read once to capture the exact pane generation; every read retains that
generation. `--count` counts emitted changes; identical text is skipped.
Retained rows are bounded by `--lines`, with explicit truncation metadata.

`proxy watch` subscribes to runtime events and emits only proxy status, runtime
stopping and resynchronization notices as JSON Lines. `--count` counts emitted
events. This observes proxy status, not captured HTTP traffic. Current proxy
configuration is startup-owned, so the initial status can be followed by an
indefinite idle period. A resynchronization notice terminates with failure.

`config reload --client ID` requests an unconditional asynchronous reload even
when watched fingerprints are unchanged. The next normal watcher cycle consumes
the request only after successful scheduling. An already running watch may
finish first. Existing validation, atomic adoption, trust checks and rejection
notifications remain authoritative; the CLI reports admission, not adoption.

`config show` reads the selected client’s adopted configuration. Sections are
`client` (default), `theme`, `gui`, `input`, `runtime`, and `binding`. Binding
indices are zero based; `input.binding_count` gives the range. Runtime values
are the client configuration for a runtime launch, not an assertion that a
running runtime has reconfigured itself. Lua callbacks are identified by their
generation/reference; their executable bodies are not serialized. The response
is JSON in both display modes. Oversized sections fail explicitly.

`plugin list --client ID` includes disabled configured plugins as well as loaded
packages. It assembles bounded pages before printing JSON, pinning the adopted
configuration generation so a concurrent reload fails instead of mixing
generations. Identifiers are loaded manifest IDs; disabled plugins can be
addressed by their configured paths.

`plugin get` returns configured path and enablement, plus loaded manifest
identity, version, entrypoint, source, revision, digest, declared capabilities
and the complete action list. Actions are paged under the same configuration
generation. Disabled packages report configuration only; inspecting them does
not load or execute code.

`plugin enable` applies a client-lifetime override to a configured plugin and
requests asynchronous configuration reload. It does not edit Lua source or
grant capabilities. Disabled entries use their configured path. Registry
loading, validation and trust checks still run on the existing worker. The CLI
reports admission; list/get distinguish adopted and requested enablement.

`plugin disable` requests the same asynchronous override with enablement false.
The fresh configuration removes bindings for that plugin before validation;
other bindings retain their order and prefix policy. Source configuration is
unchanged, so re-enabling restores its original bindings. Worker results still
pass existing package identity and capability authorization after reload.

`plugin run ID|PATH ACTION --client ID` resolves a loaded plugin action and
uses the existing isolated plugin worker. Busy, unavailable and rejected
starts return failure. Admission is not completion: worker results continue
through the existing digest-bound capability checks and UI notifications.

`diagnostics logs` reads existing `{socket}.runtime-{pid}.log` and
`{socket}.client-{pid}.log` telemetry files. It never starts or contacts the
runtime. Diagnostics are available in Debug or diagnostics-enabled builds;
missing logs return exit 2. Output is the last 100 lines per file by default,
bounded to 64 KiB per file and 64 files, sorted by filename. JSON preserves
path, component, PID, truncation and text. Symlinks and nonregular directory
entries are skipped; opened files are checked again for type and ownership.
These are telemetry logs, not terminal content or captured stderr.

## Final validation

All 82 actions in [the implementation checklist](../plans/cli-control.md) have
individual commits on `feat/cli-control`, based on `a81a49f2`. Additional commits
fix provider PATH handling, preserve non-starting semantics for new agent
commands, separate client command translation by domain, and retain integration
coverage. Runtime and clients must use the same negotiated schema (generation
63); the handshake rejects incompatible binaries.

Validated with Zig 0.16.0:

- `zig build test-runtime test-wire test-client test-gui test-cli --summary all -j4`:
  3,131 passed, one skipped; all 65 build steps succeeded.
- `python3 tools/test_cli_control.py`: 72 socket contract and failure tests.
- `python3 tools/test_cli_live.py`: two integration tests against isolated real
  runtimes, including a PTY-hosted TUI and the isolated plugin worker.
- Formatting and `codestyle` passed for all 125 changed Zig files; the client
  module/capability boundary checker passed.

The live suite covers workspace and tab mutations, pane input/read/search/watch,
telemetry logs, client discovery/detach, sidebar controls, layout round-trip,
pane split/close, forced config reload, and plugin enable/run/disable. All test
sockets, configuration and persistent data live under temporary directories.
It waits for UI negotiation before polling: existing runtime admission owns a
single handshake slot and a new arrival can preempt an unfinished handshake.

The earlier broad `test-schema` transport run stalled and was terminated;
these results do not claim that transport integration suite passed. GUI thread
expansion is covered by GUI tests; external provider accounts, external browser
opening and real host clipboard delivery were not exercised by the live suite.

## Integration with main

The CLI API and the existing change-review API coexist in protocol generation
63. CLI control retains request tags `0x33..0x36` and response tags
`0xad..0xaf`; change review uses `0x37..0x39`, `0xb0`, and `0xb1`. Golden
fixtures and the negotiated fingerprint cover both message families.

Application startup initializes its final runtime-owned storage directly.
This avoids large return-value temporaries when CLI message buffers and review
state coexist, and preserves the checkpoint restart/shutdown regressions.
The merge is checked with runtime, wire, CLI, client and GUI tests, the CLI
socket contracts, and isolated live runtime/client integration.
