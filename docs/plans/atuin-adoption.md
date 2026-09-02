# Atuin adoption plan

What telar takes from atuin (v18.21.0, 2026-08-31), ordered by dependency and
priority. The through-line: turn the history subsystem from infrastructure
into a product — trustworthy enough to record everything, scoped enough to
answer real questions, and agent-aware because that is telar's thesis.

Base: branch `herdr-adoption` (history palette, `query_history` wire,
`src/backend/history/*`). Every wire change follows the golden-corpus
discipline in `src/core/schema/handshake.zig`: corpus entries + version bump.

Explicit non-goals: dotfiles/alias sync, KV store, Atuin-AI-style command
generation, runbooks. telar feeds the agents the user already runs; it does
not compete with them.

---

## P1. Record-time filtering: secrets, patterns, and opt-outs — done

Nothing else matters if users must distrust the recorder. Refuse to record —
never redact after the fact.

- New `src/backend/history/filter.zig`: pure `shouldRecord(command, cwd) bool`
  over a pattern table. No regex engine — comptime patterns with match kinds
  (`prefix`, `substring`, `token` = substring followed by a run of
  key-charset bytes of a minimum length). Built-ins mirror atuin's set:
  AWS (`AKIA` + 16 upper/digit), GitHub (`ghp_`, `gho_`, `github_pat_`),
  npm (`npm_`), Slack webhooks (`hooks.slack.com/services/`), Stripe
  (`sk_live_`, `rk_live_`), private key headers (`-----BEGIN`), generic
  `password=`/`token=`/`secret=` assignments.
- A leading space on the command line skips recording (atuin/zsh
  `HIST_IGNORE_SPACE` convention).
- Config under `runtime.history`: `secrets_filter = true` (default),
  `command_filters = { "substring", ... }`, `cwd_filters = { "/private", ... }`
  — plain substring matches, parsed in `src/frontend/config/root.zig`
  (runtime table, next to `runtime.agents`) and plumbed through
  `src/cli/server.zig` into runtime Options like the agent manifests were.
- Hook point: the history worker right before `store.recordCommand`
  (`src/backend/history/store.zig:107` INSERT) — the observer stays
  filter-free; policy lives in one place.
- Tests: pattern unit tests per builtin, config parse/reject, worker-level
  "filtered command leaves no row". No wire change.

## P2. Author attribution: human vs agent commands

telar knows which pane runs an agent without hooks — atuin has to install
itself inside each agent to learn this. Cheapest thesis-level win.

- Schema v4 migration in `store.zig`: `command.author INTEGER NOT NULL
  DEFAULT 0` (0 human, 1 agent) + `command.provider TEXT` (manifest name,
  empty for humans). `history_schema.version` 3 → 4 with `ALTER TABLE`.
- The runtime resolves authorship when the command completes: the agent
  tracker already projects per-pane agent status; the history worker asks it
  through a narrow port (pane_id + generation → `?provider_name`), so
  history never imports agent internals.
- Wire: `HistoryEntry` += `author`/`provider`; `QueryHistory` += `author`
  filter (`all`, `human`, `agent`). Corpus + fingerprint bump.
- Surfaces: palette hides agent commands by default (config
  `client.history.show_agent_commands = false`); `telar history list/search
  --author agent|human|all`; agent rows get the provider name as a dim
  suffix in the palette row.
- Tests: migration on a v3 database, attribution port, wire corpus, palette
  default filtering.

## P3. Palette scopes and Enter/Tab semantics

The wire already supports scoping (`QueryHistory.scope` global/cwd/
workspace/pane); only the client UI is missing. This closes the "global
scope only" deviation recorded in the herdr plan (P7).

- Scope state lives in `src/frontend/client/model/history_palette.zig`
  (`scope: enum { global, workspace, cwd, pane }`), cycled with Tab while
  the palette is open: `name_prompts.dispatchInput` maps `.tab` to a new
  prompt-independent palette command; each cycle requeries.
- Scope values the client already holds: workspace path from
  `workspace_list.pathAt`, focused pane cwd from pane metadata
  (`pane_metadata.applyCwd`), pane id from the layout focus.
- The modal footer names the active scope (`goto_picker` widget `Input`
  gains `hint: []const u8`).
- Enter semantics via `client.history.enter = "paste" | "run"` (default
  `paste`); `shift+enter` (or `alt+enter` where unavailable) does the
  other one. "run" appends `\r` to the same `expressionPaste` delivery.
  Editing before running is the default flow: paste, edit in the shell, run.
- Tests: scope cycle requery (model + controller), enter-mode config parse,
  footer render. No wire change.

## P4. Import: `telar history import`

First impressions: a fresh telar should search ten years of existing
history one minute after install.

- CLI `telar history import [auto|zsh|bash|fish] [--file PATH]` in
  `src/cli/history.zig`: parsers for zsh extended history
  (`: <ts>:<dur>;cmd`, multiline continuation), plain bash histfiles
  (no timestamps → import epoch order with a synthetic clock), fish's
  `fish_history` YAML-ish (`- cmd:`/`when:`). `auto` picks by `$SHELL` and
  existing files.
- Transport: new client request `import_history = 0x22` carrying bounded
  batches (≤ 64 entries, command ≤ 64 KiB total per frame) answered by
  `request_completed`; the runtime writes them on the observation path into
  one synthetic session per import (`shell = "import:zsh"`), `author = 0`.
  The CLI streams batches sequentially. Corpus + fingerprint bump.
- Idempotence: skip exact `(command, started_at_ms)` duplicates per import
  session via `INSERT OR IGNORE` + a unique partial index scoped to import
  sessions, so re-running `import` is safe.
- P1 filters apply to imported rows too.
- Tests: each parser against fixture files, batch encode/decode corpus,
  duplicate-safe reimport, filtered secrets never land.

## P5. Delete and prune

Complements P1 for what was already recorded. Never destroy silently.

- Wire: `delete_history = 0x23` (single id) and `prune_history = 0x24`
  (bounded filters: scope + scope_value, `before_ms`, `failed_only`,
  `match` FTS string), both answered with `request_completed` carrying the
  affected count in a small `history_pruned = 0xa4` reply. Corpus + bump.
- `command_output` already cascades (`ON DELETE CASCADE`); FTS triggers
  must cover DELETE (extend the trigger set at `store.zig:375`).
- CLI: `telar history delete <id>`, `telar history prune --cwd ... --before
  <date> [--dry-run]` — dry-run prints the count using the same filters
  through `query_history`.
- Palette: `ctrl+d` deletes the selected entry (wire delete, then requery).
- Prune is destructive: the CLI asks for confirmation unless `--yes`.
- Tests: cascade + FTS consistency after delete, prune filter SQL, corpus,
  palette delete requery.

## P6. Output capture (opt-in)

telar *is* the PTY proxy atuin had to bolt on. The `command_output` table
(schema v3) has waited for its writer since the herdr work.

- Config `runtime.history.output = "off" | "bounded"` (default `off` until
  P1 has soaked — output is where secrets actually live).
- Capture: the observation emulator already replays the pane stream; the
  OSC 133 zone tracker (`src/backend/history/osc.zig`) learns the output
  span between C and D marks, keeping a bounded tail (64 KiB) per command
  in the worker; on completion the worker writes `command_output`
  (`content`, `truncated`, `observed_bytes`). Interactive path untouched —
  everything stays on the observation budget.
- Surfaces: `telar history show <id> [--output]` (new CLI verb over a
  `read_history_output = 0x25` request, bounded reply `history_output =
  0xa5`); agents get "what did the failing build print yesterday" through
  the same CLI. Palette preview is out of scope here (P8 territory at most).
- Output is not FTS-indexed (cost, secrets); note it in docs.
- Tests: zone tail bounds, truncation flag, off-by-default, wire corpus.

## P7. Fuzzy matching and palette dedup

FTS5 trigram gives substring, not fuzzy. Do fuzzy where the candidates are.

- `QueryHistory` += `match: enum { fts, fuzzy }` (default `fts`, corpus +
  bump). For `fuzzy` the history worker scans the newest N distinct
  commands in scope (N = 1000, indexed by `command_started_at`) and scores
  with a subsequence scorer — port of `model/goto_picker.zig:score` moved
  into `telar-core` (`src/core/fuzzy.zig`) so both sides share it — then
  returns the top `limit`.
- `QueryHistory` += `distinct: bool`: collapse identical command text to
  its newest occurrence (SQL `GROUP BY command` on the fts path, hash-set
  in the fuzzy scan). The palette always sets it; `history list` keeps
  duplicates.
- Palette uses `fuzzy + distinct` by default; `client.history.match =
  "fts" | "fuzzy"` overrides.
- Tests: scorer parity with goto picker, distinct on both paths, corpus.

## P8. Stats

Cheap and loved. `telar history stats [--period today|week|month|year|all]`.

- Wire: `history_stats = 0x26` request (scope + period) with a fixed-size
  aggregate reply `history_stats_result = 0xa6`: total, unique, top 10
  (command prefix, count). Corpus + bump.
- Subcommand awareness like atuin: a builtin list (`git`, `docker`,
  `kubectl`, `cargo`, `zig`, `npm`, …) groups by the first two tokens, and
  `sudo` is skipped as a prefix. Config `runtime.history.stats_subcommands`
  extends the list.
- SQL only — the indexes exist. Render as aligned rows; `--json` for
  scripts.
- Tests: grouping rules, period boundaries, corpus.

## P9. Sync — decision gate, design only

Not scheduled. Recorded so the decision is deliberate, not forgotten.

- What atuin proves: append-only per-(tag, host) records exchanged instead
  of row merges make sync conflict-free; e2e encryption (PASETO v4.local,
  per-payload keys wrapped by a master key) keeps the server untrusted.
- What telar would need first: a stable record format for command events,
  key management UX, and a server component — each bigger than everything
  above combined.
- Gate: revisit only after P1–P7 have shipped and remote attach (herdr
  P12) sees real use. If telar syncs, it syncs history records only, with
  the same "runtime owns everything" split: the runtime is the sync client,
  never the TUI.

---

## Order and verification

P1 → P2 → P3 → P4 → P5 → P6 → P7 → P8, with P9 gated. P3 has no wire
changes and can land in parallel with P2. Every phase: `zig fmt src`,
`zig build test`, a smoke test against a live runtime for wire phases, a
flow doc under `docs/flows/` when a phase crosses the socket, and one
commit per phase with status recorded back into this plan.
