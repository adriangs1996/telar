# Adopting herdr's strengths

Baseline: telar `1b04d83`, herdr v0.8.2 (2026-08-19). The comparison that
produced this list is summarized at the end. Every phase names the files and
types it touches so the work can be checked against the architecture rules in
[`engineering-invariants.md`](../engineering-invariants.md) and
[ADR 0005](../adr/0005-keep-the-live-runtime-model-in-memory.md).

Phases are ordered by dependency, not by size. A phase is done when its tests
exist, its flow document exists under `docs/flows/`, and
`zig build test` plus the perf gate pass.

```
P1 done state ──┐
                ├─> P2 agent API + skill ──> P6 hooks as official reports (optional)
P3 pane titles ─┘          │
                           └─> P4 detection manifests ──> P5b agent restore
P5a session checkpoint ─────────────────────────────────┘
P7 search UI · P8 notifications · P9 popups · P10 git · P11 auto theme (independent)
P12 remote thin client (independent, largest)
```

---

## P1. `done` agent state — done (`c01f9a3`)

An agent that finished while nobody was looking is the state a user with six
panes actually needs. herdr separates `done` (finished, not yet seen) from
`idle` (finished or waiting, seen).

**Runtime**

- `src/core/schema/types.zig` — add `AgentStatus.done = 5`. The schema
  fingerprint changes; update `src/core/schema_contract_test.zig` corpus.
- `src/backend/agent/tracker.zig` — a record gains `seen: bool`. The
  transition `working -> ready` sets `seen = false`; `projectedStatus` returns
  `.done` while `status == .ready and !seen`. `blocked` is never masked by
  `done`.
- New client request `acknowledge_agent = 0x1b` in `ClientTag`
  (`src/core/schema/root.zig`) carrying `pane_id` + `generation`. Handler in
  `src/backend/runtime/application/commands/acknowledge_agent.zig` sets
  `seen = true` and bumps the tracker revision. Focus is client state and must
  not become runtime truth, so the acknowledgement is an explicit command,
  not inferred from `update_client_layout`.
- `src/backend/agent/types.zig` — the sound decision already runs in the
  runtime (`docs/flows/agent-sound.md`). Move the audible transition from
  `working -> ready` to `working -> done` so a second attached client that
  already saw the pane does not ring.

**Client**

- `ClientModel.reconcileAgentSnapshot` already yields status transitions.
  When the focused pane's agent is `done`, `PaneFocusHandler` sends
  `acknowledge_agent`; also on attach when the pane is already focused.
- `src/frontend/widgets/sidebar.zig` and `src/frontend/graphics/icons.zig` —
  fifth glyph/color role (`agent_done`) in `src/frontend/ui/theme.zig`.

**Tests**: tracker transition table (working→ready unseen = done, blocked
wins, acknowledge flips, expiry keeps `done`); model test in
`src/frontend/client/model/tests/observations.zig`; contract bytes.

---

## P2. Agent-native API, CLI and bundled skill — done (`afcd52a`, `e0c2e1a`)

Deviations from the design below, decided while implementing:

- `read_pane` and `send_pane_text` are their own requests; `prompt` is
  `send_pane_text{mode = prompt}` and `pane send-keys` is `mode = raw`.
- Waits poll `query_agents` every 250 ms from the CLI instead of the runtime
  pushing snapshots to observers. No new handshake role was needed.
- `telar pane split` is deferred: a runtime-created pane only enters a
  client's layout through tab reconciliation, which needs its own flow.
- `TELAR_SOCKET_PATH` is read by the CLI after `TELAR_SOCKET`; the runtime
  still never injects `TELAR_SOCKET` into panes.

This is herdr's headline feature and the place where telar's existing typed
transport pays off most. The socket, handshake and schema fingerprint exist;
the CLI only exposes `history`, `notification`, `config`, `plugin`.

### Design rule

Waits are client-owned. A CLI process attaches as an observer, receives the
same `agent_snapshot` pushes UI clients get, and returns when the predicate
holds or its deadline passes. The runtime keeps no timers and no per-waiter
state, which keeps the interactive path unchanged and the API free of
"stalled waiter" bookkeeping. Verify in
`src/backend/runtime/delivery/root.zig` that agent snapshots reach a client
that has attached no pane; add an `observer` handshake role in
`src/core/schema/handshake.zig` if delivery currently gates on attachment.

### Protocol additions (`src/core/schema/root.zig`, `codec.zig`)

| Tag | Direction | Purpose |
|---|---|---|
| `query_agents = 0x1c` | client | one-shot list; response `agent_snapshot` |
| `read_pane = 0x1d` | client | `pane_id`, `rows ≤ 200`, `source = screen \| recent`, `ansi: bool`; response `pane_text = 0xa0`, bounded by `max_frame_size`, `truncated` flag |
| `acknowledge_agent` | client | from P1 |

`prompt` needs no new tag: it is `pane_input` with the text wrapped in
`ESC[200~ … ESC[201~` when the pane's `InputModes.bracketed_paste` is set
(`src/core/schema/frame.zig:45`), followed by `\r`. The CLI reads the mode
from the agent entry, so `AgentSnapshotEntry` gains `bracketed_paste` and
`generation`. A prompt to a `blocked` agent is refused with
`FailureCode.agent_blocked` in the runtime, not the CLI, so plugins and Lua
get the same guarantee.

`read_pane` renders rows from `vt.Screen` in the observation worker, reusing
the text extraction in `src/backend/history/observer.zig` (`batch_bytes`
sample). It never runs on the event loop.

### Child environment (`src/backend/pty/environment.zig`)

Today `TELAR_SOCKET` is deliberately removed from the child map (line 47).
Reinstate it under a name that cannot be confused by a nested telar:
`TELAR_SOCKET_PATH`, plus `TELAR_PANE_ID`, `TELAR_TAB_ID`,
`TELAR_WORKSPACE_ID`. The existing `outer-telar` test keeps proving that a
nested runtime does not inherit the outer socket.

### CLI (`src/cli/`)

```
telar agent list [--json]
telar agent get <pane|name> [--json]
telar agent wait <pane|name> --until done|ready|blocked|working [--timeout 30s]
telar agent prompt <pane|name> "text" [--wait]
telar agent read <pane|name> [--lines N] [--ansi]
telar pane split <pane> --direction right|down [--cwd] [-- argv]
telar pane read / send-keys / focus / close
telar workspace list|create|focus
telar api schema        # prints the schema fingerprint and message table
telar --skill           # prints the embedded agent skill (markdown)
```

`--current` resolves the caller's pane from `TELAR_PANE_ID`. Names resolve
against the agent title (`AgentTitleSource.manual` wins). New parser cases in
`src/cli/parser.zig`, one file per command family following `history.zig`
(connect → encode → receive → print). `--json` output uses fixed writers, no
allocation beyond the receive buffer.

The skill is a markdown file under `src/cli/skill/telar.md` embedded with
`@embedFile`; `telar --help` ends with "Agents: run `telar --skill`". Its
content is the CLI table above plus the three rules an agent needs: prompt is
refused while blocked, waits are bounded, `read` is a snapshot.

### Security

Any local process with socket access can already show notifications and
query history. Driving input is stronger. Keep the socket owner-only (already
0700 dir), require the pane generation in every mutating request so a stale
caller cannot hit a reused pane id, and rate-limit `pane_input` from observer
role clients to the same byte budget as UI clients.

**Tests**: `src/backend/runtime/tests/{query_agents,read_pane,acknowledge_agent}.zig`,
CLI parser tests, one `src/transport_integration_test.zig` flow that starts
a runtime, spawns a fake agent, and runs `agent wait --until done`.

---

## P3. Terminal titles (OSC 0/2) and host window title — done

Deviation: titles are not yet agent evidence; that waits for the manifests in
P4. Tab labels keep their own semantics; the title reaches the sidebar as the
placeholder session title, the Lua bar context and the host window title.

Telar handles OSC 133/7/52 and nothing else. Titles are free evidence the
emulator already parses, and herdr uses them as a detection signal (Claude
Code's spinner frames live in the title).

- `src/backend/pane/root.zig` — implement the ghostty-vt stream handler for
  title changes; store `title: [128]u8` + `title_len` on `Pane`, revisioned.
- New server message `pane_title = 0xa1` next to `pane_cwd`/`pane_foreground`
  (same delivery cursor pattern).
- `src/backend/agent/types.zig` — `TitleObservation { identity, text }`;
  `Tracker.observeTitle` at a confidence between screen heuristics and proxy.
  Detection phrases for titles come from the manifests in P4.
- Client: `AgentTitleSource.terminal = 3` as the lowest-priority tab label
  source; Lua bar token `telar.bar.pane_title()`; config
  `client.window_title = "{hostname}: {workspace} · {pane_title}"` rendered
  as OSC 0 to the host from `src/frontend/presentation/screen.zig`, throttled
  to once per frame and only on change.

**Tests**: pane title bound and strip of control bytes; tracker precedence;
model label fallback order; `docs/flows/pane-title.md`.

---

## P4. Detection rules as data — done

Deviations: `AgentProvider` stays an enum, made non-exhaustive, with custom
indexes assigned from configuration; `provider_name` travels in the snapshot
entry. Proxy host mapping and SSE turn parsing remain built-in code.
`telar agent explain` is covered by `telar agent get --json`, which already
reports source, confidence and authority.

`src/backend/history/agent_detection.zig:39-80` hardcodes phrases for two
providers. herdr ships 21 agents because its rules are TOML manifests.

- New `src/backend/agent/manifest.zig`: fixed-capacity table
  (`max_agents = 32`, `max_phrases = 16` per state, `max_phrase_bytes = 64`,
  `max_process_paths = 8`, `max_hosts = 4`). Fields: `name`, `process_paths`,
  `title_working`, `screen_working`, `screen_blocked`, `screen_ready`,
  `hosts`, `turn_parser: enum { none, anthropic_sse, openai_sse }`,
  `resume: ?ResumeSpec` (used by P5b).
- Defaults for `claude` and `codex` move into a built-in manifest; users add
  or override via Lua `runtime.agents = { { name = "gemini", ... } }`
  validated at config load like every other section in
  `src/frontend/config/root.zig`, and shipped to the runtime in
  `RuntimeSnapshot` (`src/frontend/config/model.zig`).
- `schema.AgentProvider` becomes an index into the table plus a bounded name
  in `AgentSnapshotEntry`, so clients render names they have never compiled.
- `src/backend/proxy/provider/request.zig` host mapping reads the table;
  SSE turn parsers stay native and are selected by `turn_parser`.
- `telar agent explain <pane> --json` dumps the tracker's evidence list
  (source, confidence, timestamp, expiry) — the invariants already require
  every observation to carry those fields, so this is a projection, not new
  state.

**Tests**: manifest bounds and rejection of over-long phrases; detection
tests re-run against the built-in manifest; config round trip.

---

## P5a. Session checkpoint on disk — done

Deviation: the store is a private binary checkpoint file with atomic replace
rather than SQLite; the records are written with the wire codec but stay
separate types. Panes restore as a relaunch of their original command in
their last cwd, which is what `PaneLifecycle.restored` would have flagged; the
sidebar shows them as fresh panes.

ADR 0005 specifies this and nothing implements it. Today runtime death loses
workspaces, tabs, layout and history session identity;
`ClientLayoutStore` keeps eight layouts in memory only.

- `src/backend/persistence/` — port `Persistence` with `Volatile` and
  `Sqlite` adapters. Records (separate types from aggregates and wire):
  `WorkspaceRecord{id,name,path,order}`, `TabRecord{id,workspace,label,order}`,
  `PaneRecord{id,tab,cwd,kind,agent_session_ref?}`,
  `ClientLayoutRecord` (the `StoredTab` arrays from
  `client_layout_store.zig`, keyed by `ClientIdentity`), plus the id
  counters so restored ids stay stable.
- Storage: `session.sqlite` next to the history DB (same worker, WAL,
  owner-only, atomic checkpoint in one transaction; on load failure keep the
  file as `session.sqlite.corrupt-<ts>` and start empty).
- Commit policy: write-behind, debounced 500 ms after the last semantic
  change, submitted from command handlers
  (`create_workspace`, `create_tab`, `rename_*`, `move_tab`, `close_*`,
  `open_pane`, `update_client_layout`). No handler waits for the write.
- Restore in `src/backend/runtime/instance.zig` before the listener accepts:
  recreate workspaces and tabs, relaunch each pane as a shell in its saved
  cwd with `PaneLifecycle.restored` so the sidebar can say "restored" instead
  of pretending continuity. Clients reconnecting after a restart get their
  layout replica back because pane ids are stable.
- Config: `runtime.session.persist = true`, `runtime.session.path`.

**Tests** (ADR 0005 lists them): restart round trip, corrupt file, wrong
owner mode, stale generation, disk full (fault-injected writer), queue
saturation, worker failure. Perf gate: zero steady-state allocation on the
interactive path; checkpoint latency reported as p50/p95/p99 in
`benchmarks/main.zig`.

---

## P5b. Native agent session restore — done

Deviation: the reference comes from an explicit `report_agent_session`
request (`telar agent report-session`, which P6 hooks call with the
`session_id` they receive) rather than from the proxy body; the Claude Code
binary does not expose the `metadata.user_id` template, so that source stays
unverified. Resume is typed into the relaunched shell instead of replacing
the pane command, so the shell survives the agent exiting.

Depends on P4 (manifest `resume` spec) and P5a (typed reference persisted).

- `AgentSessionRef { provider_index, id: [36]u8, cwd, observed_at_ms }`.
  Sources, by priority: an official hook report (P6) if installed; the
  proxy request body (Claude Code sends its session id inside
  `metadata.user_id` — verify against a live capture before relying on it;
  the proxy already parses the JSON to find `stream`/`tools`); otherwise
  none. Invariants: reject option-looking, duplicate, stale or wrong-owner
  references before launch.
- Manifest `resume = { argv = {"claude", "--resume", "{session}"} }` for the
  built-in providers only; user manifests may not add resume specs (official
  allowlist rule). The runtime reconstructs a fixed argv and launches it
  through the existing launch transaction (ADR 0001) with state `resumed`.
- Config `runtime.session.resume_agents = true`. UI marks the pane
  `resumed` until the tracker confirms the process.

**Tests**: reference validation table; restore with allowlisted vs foreign
provider; argv never contains user bytes beyond the validated UUID.

---

## P6. Lifecycle hooks as official reports (optional) — done

`telar integration install claude` registers `telar hook claude` on five
events; reports carry `AgentSource.lifecycle_report` and outrank inferred
evidence until they expire. `TELAR_PANE_GENERATION` joins the pane
environment so a hook addresses its exact pane generation without a lookup.

`docs/proxy-tls.md` says telar does not depend on harness hooks. The
invariants, however, rank "full official lifecycle reports" above every other
evidence source. Both hold if hooks are one more `Tracker.observe*` input
that never becomes a dependency.

- `telar integration install claude` writes `Stop`, `Notification`,
  `SessionStart`, `UserPromptSubmit` hooks into `~/.claude/settings.json`
  calling `telar agent report --pane $TELAR_PANE_ID --state <s>
  --session <id>`; `uninstall` and `status` mirror herdr. Preserve key order
  and formatting of the user's file.
- `report_agent = 0x1e` request; `Tracker.observeReport` with top precedence
  and the shortest expiry, so the proxy takes over the moment hooks go
  silent.
- This also gives P5b its most reliable session reference.

---

## P7. Search in the UI — copy-mode search done; pickers pending

`/`, `?`, `n`, `N` work in copy mode through `search_pane`/`pane_matches`.
The goto picker and the history palette remain open; they need a list-modal
capability that does not exist yet.

Nothing in the client searches today; `copy_mode.zig` has no find.

- Copy mode `/` and `?`: scrollback lives in the runtime, so add
  `search_pane = 0x1f` (`pane_id`, needle ≤ 256 B, direction, from row,
  smart-case) answered by `pane_matches = 0xa2` with ≤ 64 `(row, col, len)`.
  Runs in the observation worker over the ghostty-vt page list. The client
  moves the copy-mode cursor and requests the viewport it already knows how
  to request (`set_pane_viewport`).
- Goto picker (`prefix+g`): client-only modal over the agents snapshot,
  workspace list and tab descriptors it already holds; fuzzy score into a
  fixed `[64]` result array; reuse the name-prompt editor
  (`src/frontend/input/edit.zig`) and the modal border
  (`src/frontend/graphics/modal.zig`).
- History palette (`prefix+/`): same modal over `query_history` results with
  scope toggles; Enter pastes the command into the focused pane. This is the
  first UI consumer of the FTS5 work.

---

## P8. Notification delivery beyond the toast — done

Deviation: the runtime's `agent_sound` event kept its shape; the delivery
policy hooks the client's notification publication instead, so actionable
agent alerts, runtime notices and local diagnostics all follow one setting.

- Generalize the `agent_sound` server event (`schema.types.zig:240`) into
  `agent_transition { pane, generation, from, to }`; keep the tag, extend the
  payload. The runtime keeps deciding *which* transitions are notable; the
  client decides *how* to surface them.
- Config `client.notifications.delivery = "telar" | "terminal" | "system"`
  and per-agent overrides, mirroring `client.sound`.
  `terminal` writes OSC 9 / OSC 777 to the host from the presentation layer;
  `system` spawns `osascript` / `notify-send` from a worker built on
  `src/frontend/sound/worker.zig` (bounded queue, single child, timeout).

---

## P9. Popup panes

- A popup is an ordinary runtime pane; only placement is client state.
  `ClientLayoutUpdateView` gains `popup: ?PaneId`; the layout tree is
  untouched.
- Action `popup { command = {...}, width = "80%", height = "80%" }` in
  `src/frontend/input/action.zig`; the client sends `create_pane` with the
  argv and cwd of the focused pane, renders it over the layout using the
  modal border, routes input to it while visible, and closes it on
  `pane_exited`.

---

## P10. Git in the sidebar, worktrees per workspace — status done; worktrees pending

Branch and dirty state are observed per workspace on the maintenance tick
and rendered in the workspace list. `telar workspace create --worktree`
remains open.

- Observation worker in the runtime: branch from reading `.git/HEAD` (no
  subprocess, ≤ 4 KiB), dirty flag from `git status --porcelain` at
  ≥ 5 s intervals with a 2 s timeout and one child at a time (the
  `agent_description` coordinator already implements this shape).
- `workspace_list` snapshot gains `branch` and `dirty`; sidebar space rows and
  Lua bar tokens read them.
- `telar workspace create --worktree <branch>` runs `git worktree add` in the
  worker and creates the workspace on success; `runtime.worktrees.directory`
  config.

---

## P11. Automatic light/dark theme — done

Deviation: the background is queried at startup and on every host resize
rather than on focus-in (the client does not enable host focus reporting),
and Mode 2031 forwarding to children stays with ghostty-vt.

- Host capability probe (`docs/flows/host-capabilities.md`) adds OSC 11;
  re-query on focus-in (focus events already reach the client). Luminance
  picks `client.theme.light` / `client.theme.dark`; `client.theme.auto_switch`.
- Forward the host appearance to children as Mode 2031 / DSR 996 replies
  through ghostty-vt if the emulator surfaces the query; otherwise leave it.

---

## P12. Remote thin client over SSH — done

Deviation: instead of a stdio bridge, `--remote` forwards the remote Unix
socket over OpenSSH (`-L local.sock:remote.sock`), which preserves the local
transport byte for byte. `telar server endpoint` is the discovery command,
and shared-memory graphics are disabled for forwarded clients.

The invariant already states remote transport keeps local framing, bounds,
negotiation and backpressure.

- `endpoint.Remote` in `src/core/transport/endpoint.zig`;
  `src/frontend/transport/stdio.zig` speaks the same frames over the
  stdin/stdout of `ssh host telar server attach-stdio`. Handshake and
  fingerprint unchanged; one OpenSSH connection reused via ControlMaster.
- `telar server attach-stdio` in `src/cli/server.zig`: a local client that
  bridges the Unix socket to its stdio.
- Graphics: shared-memory delivery is a per-client capability, so remote
  clients negotiate `graphics_image_chunk` only. Clipboard already goes to the
  local host via OSC 52 because the client is local.

---

## Deliberately not adopted

- Windows/ConPTY.
- Unreviewed plugin marketplace. Discovery could later sit on the existing
  SHA-256 trust model.
- Screen scraping as the primary evidence source.

## Summary of the comparison

telar leads on depth: TLS proxy with per-pane credentials and turn detection,
FTS5 command history, end-to-end KGP, sandboxed Lua, plugin trust by digest,
per-client ACK delivery. herdr leads on breadth and first-day experience:
survives a restart, 21 agents, agents drive themselves through a CLI, `done`
state, remote thin client, search, popups, git-aware sidebar. Phases P1–P5
close that gap; P2 is where existing work yields the most.
