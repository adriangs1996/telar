# Atuin AI adoption plan

What telar takes from `atuin ai` (atuin `711b96f`, 2026-09-02; `atuin-ai-core`
and `atuin-ai-server` at the same date), ordered by dependency. The through-line:
the information telar already owns, command history and command output, must
reach the models that work on the user's machine, both telar's own engine and
the agents running in panes. Atuin built a model server and a tool loop to get
there; telar keeps borrowing the brain (pi in RPC mode, any agent in a pane) and
only builds the pipes.

This narrows the non-goal recorded in [`atuin-adoption.md`](atuin-adoption.md):
telar still does not build a model server, accounts or a permission language.
It does give models read-only access to its history, and it does make the
command suggestion structured and safety-scored.

Base: `main` after the pi integration merge (`ac099ea`) with the engine
(`src/backend/engine`), the suggestion palette (`docs/flows/suggest-command.md`)
and the history wire (`query_history`, `read_history_output`). Every wire change
follows the golden-corpus discipline in `src/core/schema/handshake.zig`.

What atuin does that telar deliberately does not copy: the Gleam server, Hub
accounts and credits, `permissions.ai.toml` (the engine never executes), the
skills loader and `TERMINAL.md` (pi has its own context files and skills),
web search and scrape.

---

## P0. Engine conversation isolation — done

The engine reuses one pi child across prompts and never sends `new_session`
(`src/backend/engine/rpc.zig` encodes only `prompt` and
`get_last_assistant_text`). Every suggestion therefore continues the previous
conversation: a request from client A is answered with client B's screen rows
still in context, and the context grows until pi compacts it. Atuin scopes a
session to one cwd or git root and one client; the engine has to at least
scope it to one request.

- `rpc.encodeCommand(&buffer, "new_session")` before each prompt in
  `Session.exchange`; treat a failed or `cancelled = true` reply as a protocol
  failure that kills the child, like a rejected prompt.
- P4 relaxes this to "one conversation per palette session"; until then the
  rule is one prompt, one conversation.
- Tests: `session.zig` fake proves the reset is sent before the prompt and
  that a refused reset discards the child; `service.zig` proves two prompts
  from different purposes never share a session. No wire change.
- Verified live on 2026-09-03 with pi 0.84.4: under `--no-session`,
  `new_session` answers `{"command":"new_session","success":true,
  "data":{"cancelled":false}}`, and command replies interleave with other
  records, which is why the session waits for the reset reply instead of
  assuming order.

## P1. History tools for the agents the user already runs

Atuin's cheapest high-leverage piece is giving models two read-only tools,
history search and command output, and a short instruction block telling the
agent to prefer them over `~/.zsh_history`. telar has the queries on the wire
and the CLI; what is missing is machine-readable output and tool registration
where telar controls the agent. No MCP server: pi has none by design, the
engine is pi, and Claude Code and Codex already reach the CLI through the
skill telar installs. What that costs is discoverability, the tools are not in
those agents' tool list until the skill is read, and the skill update below is
where that is paid.

- CLI: `--json` on `telar history search|list|show`, one object per row with
  id, command, cwd, exit code, duration, started_at, author and provider;
  `show` adds `truncated`, `observed_bytes` and the text. `show` gains
  `--range start:end` (repeatable, at most 10; 0-based, inclusive, negative
  from the end; default `0:1000`) applied client-side over the 64 KiB tail,
  overlapping ranges merged, gaps rendered as `[...skipped N lines...]`,
  lines prefixed with their number and a tab. The tail is raw VT bytes: strip
  CSI/OSC/SGR with a bounded scanner before printing text meant for a model
  (new pure module beside `src/backend/history/escape.zig`, or in
  `telar-core` if the palette preview later wants it too). When capture is off
  (`runtime.history.output = "off"`) `show` says so in the JSON instead of
  returning an empty text, atuin's `NO_OUTPUT_ADVICE`.
- pi: the bundled `src/cli/integration/pi.ts` registers `telar_history` and
  `telar_output` with `pi.registerTool()`, shelling out to the two commands
  above; `promptSnippet` and `promptGuidelines` carry the scope and author
  guidance atuin puts in its tool descriptions. The tools work anywhere the
  `telar` binary and socket are reachable, inside a pane or as the engine
  child (P3). Tool names mirror atuin's so prompts written for one work on
  the other.
- Skill: `src/cli/skill/telar.md` gets a "History" section with the two
  commands, the scopes, the author filter and when to use them. That is the
  whole integration for Claude Code and Codex.
- Tests: JSON encoding per command, range selection and merging, escape
  stripping, output-off advice, extension tool schema pinned by a fixture.
  No wire change.

## P2. Structured suggestion with a danger score

Atuin's `suggest_command` carries `confidence` and `danger`, and its server
overrides the model's `danger` with a keyword scan. telar's palette parses the
first non-empty line of free text (`suggestion.extractCommand`). Enter only
pastes, so the exposure is smaller, but a pasted `rm -rf` still deserves a
badge before the human presses Enter in the shell.

- Prompt: ask pi for one JSON line
  `{"command": ..., "description": ..., "danger": "low|med|high",
  "confidence": "low|med|high"}` and nothing else. Parse it with the bounded
  parser already in `engine/rpc.zig`; when the reply is not JSON, keep
  `extractCommand` as the fallback with `danger = unknown`.
- Local scanner `src/core/danger.zig`, pure `assess(command) Danger`, comptime
  patterns with match kinds like `history_filter.zig` (no regex engine).
  Categories from atuin's `safety.gleam`: recursive delete of `/`, `~`, `*`;
  `dd of=/dev/…`; `mkfs|wipefs|sgdisk`; `chmod -R 777`; download piped to a
  shell; fork bomb; plus `sudo` as `med`. The scanner only escalates, never
  lowers, the model's value, exactly like atuin's server check.
- Wire: `CommandSuggestion` += `danger: enum(u8) { unknown, low, med, high }`
  and `description ≤ 256 bytes`. Corpus + fingerprint bump.
- Palette: the row shows the description dimmed and a danger badge; `high`
  needs a second Enter to paste (mirrors atuin's double Enter), and the footer
  says why. Config `client.suggestion.confirm_danger = "high" | "med" | "off"`
  (default `high`).
- Tests: JSON reply parsing and fallback, scanner per category, escalation
  never lowers, corpus, palette second-Enter state machine
  (`src/frontend/client/model/suggestion.zig`). Update
  `docs/flows/suggest-command.md`.

## P3. Engine tools: let the suggestion engine read telar's history

The real advantage of `atuin ai` is that the model pulls `atuin_history` and
`atuin_output` when the screen is not enough. telar has the data; the engine
child starts from `/` with `--no-tools` and cannot reach it. pi has no MCP, so
the vehicle is the same extension P1 bundles.

- Runtime side: when `runtime.engine.tools = { "history" }` is configured, the
  runtime launches the engine with `--no-extensions -e <bundled telar.ts>
  --tools telar_history,telar_output` and the socket environment the pane
  children already receive (`TELAR_SOCKET_PATH` and the pane-less identity the
  CLI accepts). Built-in pi tools stay off; the allowlist is the permission
  model, and it is read-only by construction.
- Prompt: add the focused pane's last completed command as
  `Last command: #<id> <command> (exit <code>, <duration>)` so the model can
  call `telar_output` with the id directly, atuin's `last_command` with a
  History ID. Keep the 24 screen rows; they are the cheap path and usually
  enough.
- Budgets: a tool loop costs seconds. `runtime.engine.timeout_ms` already
  bounds the whole exchange; document that enabling tools wants 20 s or more,
  and keep `max_reply_bytes` (the reply is still one JSON line).
- Privacy: this is the opt-in that lets a model read command output. Off by
  default; the docs list what the tools can return and that P1's escape
  stripping applies.
- Tests: launch arguments derived from config, prompt carries the last
  command id, fake engine that issues a tool call round trip (extend
  `engine/testing.zig` with a shell fake that echoes a `tool_execution_start`
  record before settling, so the engine proves it skips events it does not
  own). Update `docs/flows/engine.md` and `configuration.md`.

## P4. Follow-up in the palette

Atuin lets the user refine a suggestion (`f`) inside the same conversation.
With P0 resetting per prompt, the palette cannot say "no, in bash". Small and
worth it once P2 gives the palette a description to react to.

- Wire: `SuggestCommand` += `parent_request_id: RequestId` (0 = fresh).
  Corpus + bump.
- Engine: `Purpose.Suggestion` gains `conversation: u64` (the first request
  id of the chain). `Service` keeps `conversation_owner: ?u64` for the live
  child and sends `new_session` only when the owner changes or the child is
  fresh; the idle kill still ends every conversation. One conversation at a
  time, no queue of conversations: a request for another owner resets.
- Palette: after a ready suggestion, typing does not discard it; Enter asks
  again with the parent id; the previous suggestion stays visible dimmed
  above the new one. Escape closes the chain.
- Tests: owner change forces a reset, same owner reuses, palette chain state,
  corpus.

## P5. Engine instructions file — design only

Atuin loads `TERMINAL.md` from the project and the config directory into the
prompt. The engine starts from `/`, so pi's own `AGENTS.md` discovery is off by
design. If P3 shows the model keeps missing user conventions (preferred tools,
shell dialect, aliases), add `runtime.engine.instructions = "<path>"` passed as
`--append-system-prompt`, bounded at 8 KiB and read once at launch. Not
scheduled; recorded so it is not reinvented as something bigger.

---

## Order and verification

P0 → P1 → P2 → P3 → P4, P5 gated on P3 evidence. P1 and P2 are independent
and can land in parallel once P0 is in. Every phase: `zig fmt src`,
`zig build test`, a smoke test against a live runtime for wire phases (P2, P4)
and against installed pi for P1, a flow doc under
`docs/flows/` when a phase crosses the socket, and one commit per phase with
status recorded back into this plan.
