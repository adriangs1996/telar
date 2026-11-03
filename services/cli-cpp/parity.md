# CLI parity with the Zig `telar`

The C++ `telar` replaces the Zig CLI in `src/cli`, which will then be deleted.
Every command must behave as the Zig one does for a user or an agent: the same
arguments and validation, the same stdout (text and `--json`), the same stderr
messages and exit statuses, and the same effects, against the C++ runtime and
GUI. Nothing may call the Zig binary.

## How parity is checked

- Help is data: `help/` holds the texts the Zig CLI printed at `b8be74a45`, and
  `cli-help-tests` checks that `telar ... --help` prints each of them and finds
  help where Zig did. Change a text there when a command's behavior changes.
- Commands that only read or write files are compared directly: run the Zig and
  the C++ `telar` on copies of the same directories, as `tools/check_hook_cli.py`
  and `tools/check_integration.py` do.
- Commands that talk to a runtime are compared stack against stack: Zig `telar`
  with its Zig runtime against C++ `telar` with `telar-runtime`, from the same
  state, normalizing only ids and times. The two runtimes speak different wire
  schemas, so a C++ probe cannot drive the Zig runtime.
- Commands that act through a window need the C++ GUI attached
  (`ClientCommand`); a command the GUI cannot perform yet is a GUI gap, recorded
  here, not a reason to change the CLI's contract.
- Each comparison leaves a script under `tools/` and, where it does not need the
  Zig binary, a CTest that keeps the behavior once Zig is gone.

Status: **done** matches Zig by the named check; **partial** runs with recorded
differences; **unverified** runs without a comparison; **missing** prints
"is not implemented by this telar yet" and exits 1.

## Entry points

| Entry point | Status | Notes |
| --- | --- | --- |
| `telar --help`, `FAMILY --help`, `FAMILY COMMAND --help`, `-h` | done | `cli-help-tests`; 155 cases matched Zig byte for byte. |
| `telar --version`, `-V` | done | |
| `telar --skill [telar\|coordinator]` | done | Embedded from `integration/assets/` (no Zig source dependency). |
| `telar` with no arguments, `telar COMMAND...` | done | `check_window_parity.py`: real Zig/C++ windows launch the same child, exit on SIGTERM and leave runtime/child alive; `check_window_launch.py` checks sibling/bundle/PATH argv. |
| `--config`, `--no-config`, `--profile`, `--theme`, `--fresh`, `--remote` before COMMAND | done | `check_machines_launch.py` validates flags against Zig; real window/profile/fresh and localhost SSH machine selection in `check_window_parity.py`, `check_window_launch.py`, `check_machine_ssh.py`. |
| `telar --machine LABEL ...`, `dispatch-argv` | done | `check_machines_launch.py`: literal argv, local/remote labels, help, decode errors and statuses; `check_machine_ssh.py`: real isolated localhost SSH, stdin/stderr, disabled explicit profile and GUI remote launch. |
| `plugin-worker` | forwarded | `telar` exec's `telar-runtime plugin-worker`; the worker belongs to the runtime. |
| Usage errors | partial | `main` prints Zig's format, `telar: MESSAGE; see \`telar FAMILY [COMMAND] --help\``, exit 1; each family still has to use Zig's messages. |

## Commands

| Command | Status | Notes |
| --- | --- | --- |
| `workspace create` | done | `tools/check_sessions_cli.py --cpp CPP --zig ZIG`: `workspace-create`, autostart, symlink resolution, wire validation and `--worktree` alias; `cli-sessions-tests`. Source: `src/cli/workspace.zig:51`, `arguments/WorkspaceOptions.zig:25`. Both wire encoders cap names at 128 bytes despite the 256-byte help/parser limit. |
| `workspace get` | done | Same comparison: `workspace-get*`, `--current`, underscored ids and missing identities; `cli-sessions-tests`. Source: `src/cli/workspace.zig:130` and `workspace_output.zig:6`. |
| `workspace list` | done | Same comparison: empty/nonempty text and JSON, missing runtime (never starts one), final workspace closure; waits for both retained Git probes to settle. Source: `src/cli/workspace.zig:130`; `cli-sessions-tests`. |
| `workspace rename` | done | Same comparison: text/JSON, quotes, UTF-8, parser and wire limits. Source: `src/cli/workspace.zig:102`, `arguments/WorkspaceOptions.zig:40`; `cli-sessions-tests`. |
| `workspace select` | partial | `check_sessions_cli.py --cpp CPP --zig ZIG --gui CPP_GUI`: real windows, missing client and repeated selection. CLI route/status validation matches `src/cli/routed.zig:27`; C++ GUI answers `admitted` for an already selected workspace where Zig answers `applied` (`services/gui-cpp/application/session.hpp:3618`). |
| `tab close` | done | `check_sessions_cli.py`: close a tab and the last tab, JSON and filesystem/session effects; `cli-sessions-tests`. Source: `src/cli/TabControl.zig:66`. |
| `tab create` | done | Same comparison: `--background` and real-GUI `--client`, labels, missing clients; GUI tab list confirms creation. `cli-sessions-tests` keeps the background path. Source: `src/cli/tab.zig:99`, `arguments/RoutedOptions.zig:40`, `routed.zig:27`. |
| `tab get` | done | Same comparison: text/JSON pane generations/lifecycle, current and missing targets; `cli-sessions-tests`. Source: `src/cli/TabControl.zig:43`, `pane_output.zig:6`. |
| `tab list` | done | Same comparison: text/JSON, inherited workspace and runtime order after moves; `cli-sessions-tests`. Source: `src/cli/tab.zig:31`. |
| `tab move` | done | Same comparison: previous/next, relative target and readback ordering; `cli-sessions-tests`. Source: `src/cli/TabControl.zig:24`, `arguments/TabOptions.zig:51`. |
| `tab next` | partial | Real-GUI stack comparison: C++ GUI changes `target_id` in completion (`services/gui-cpp/application/session.hpp:3613`), so the runtime cannot match the request and the CLI times out (exit 3); Zig completes the navigation. Missing-client and argument contracts match `src/cli/arguments/RoutedOptions.zig:112`, `routed.zig:27`. |
| `tab previous` | partial | Same real-GUI completion mismatch as `tab next`: C++ GUI changes the original target 0 to the selected tab id. Source: `services/gui-cpp/application/session.hpp:3613`; `check_sessions_cli.py` records the timeout. |
| `tab rename` | done | Same comparison: text/JSON, quotes, label limits and control-byte refusals; `cli-sessions-tests`. Source: `src/cli/TabControl.zig:52`, `arguments/TabOptions.zig:38`. |
| `tab select` | partial | Real-GUI comparison includes already selected and changed tabs. C++ GUI leaves the status `applied` for a changed tab (`services/gui-cpp/application/session.hpp:3636`), where Zig admits an asynchronous handoff. CLI request/reply identity checks match `src/cli/routed.zig:27`. |
| `pane close` | done | `check_pane_agent_cli.py`: native window routing, text/JSON, applied/admitted/refused replies match Zig; `check_pane_gui.py`: closure confirmed by topology. Reference: `src/cli/arguments/RoutedOptions.zig:103`, `src/cli/routed.zig:31`. |
| `pane copy` | done | Same routing comparison; C++ GUI copy admitted. Inclusive range validation matches `src/cli/arguments/RoutedOptions.zig:73`, `src/core/schema/messages/CopySelection.zig:15`; `pane-agent-cli-tests`. |
| `pane create` | done | Same routing comparison; C++ GUI creation confirmed by topology (`check_pane_gui.py`). Reference: `src/cli/arguments/RoutedOptions.zig:111`, `src/cli/routed.zig:31`. |
| `pane focus` | done | Native window routing matches Zig; C++ GUI focus applied. Directional no-owner failure matches both runtimes; success/reason/generation covered by `pane-agent-cli-tests`. Reference: `src/cli/pane.zig:172`, `src/cli/arguments/PaneOptions.zig:64`. |
| `pane fullscreen` | done | Native window routing matches Zig; C++ GUI toggles return 1 then 0 (`check_pane_gui.py`). Reference: `src/cli/arguments/RoutedOptions.zig:94`, `src/cli/routed.zig:31`. |
| `pane get` | done | `check_pane_agent_cli.py`: current, missing, zero and filtered topology match Zig; `pane-agent-cli-tests`. Reference: `src/cli/pane.zig:202`. |
| `pane list` | done | Same stack comparison and CTest: JSON/text topology and workspace/tab/current filters. Reference: `src/cli/PaneCatalog.zig:16`, `src/cli/PaneRecord.zig:10`. |
| `pane read` | partial | CLI arguments, errors and formatting match; stack comparison exposes C++ runtime trimming an explicit final space (`"❯ "` becomes `"❯"`). `check_pane_agent_cli.py`; `pane-agent-cli-tests` protects exact wire text/escapes. Reference: `src/cli/pane.zig:121`; runtime path: `services/runtime-cpp/terminal/text_reader.hpp:18`. |
| `pane resize` | done | Native window routing matches Zig; C++ GUI resize applied (`check_pane_gui.py`). Reference: `src/cli/arguments/RoutedOptions.zig:95`, `src/cli/routed.zig:31`. |
| `pane scroll` | done | Native window routing matches Zig; C++ GUI scroll applied. Signed delta validation matches `src/cli/arguments/RoutedOptions.zig:90`; `pane-agent-cli-tests`. |
| `pane search` | done | `check_pane_agent_cli.py`: empty and populated searches; text/JSON match Zig. `pane-agent-cli-tests` checks coordinates. Reference: `src/cli/pane.zig:94`. |
| `pane send-keys` | done | Stack comparison: input/Enter and stdin errors match Zig. CTest: 150 ms submit delay, stdin trimming, focused/gone panes and limits. Reference: `src/cli/pane.zig:63`, `src/cli/pane.zig:153`. |
| `pane split` | done | Native window routing matches Zig; C++ GUI vertical split confirmed by topology. Reference: `src/cli/arguments/RoutedOptions.zig:104`; `check_pane_gui.py`. |
| `pane watch` | partial | Same runtime final-space difference as `pane read`. Stack comparison and CTest cover JSONL, generation pinning, text deduplication, count and polling. Reference: `src/cli/PaneWatcher.zig:20`. |
| `worktree create` | partial | Local stack comparison covers checkout, duplicate rejection, default source workspace, alias, setup authorization, recipes, symlink refusal and effects; `cli-sessions-tests`. Source: `src/cli/worktree.zig:129`, `project_setup.zig:33`. `--machine` dispatch remains pending the machine/repository ports; it fails explicitly without running Git or starting a local runtime. |
| `worktree diff` | done | Same comparison: base/uncommitted diff, diffstat, empty diff and adopting an untracked linked checkout; `cli-sessions-tests`. Source: `src/cli/worktree.zig:479`, `worktree_git.zig:221`. |
| `worktree exec` | done | Same comparison: branch/title lookup (case insensitive titles), background launch, literal argv, wait text/JSON, nonzero exit and timeout (pane remains running); `cli-sessions-tests`. Source: `src/cli/worktree.zig:200`, `lib/pty/login_shell.zig:69`. |
| `worktree fetch` | partial | Argument grammar/validation ported and compared by `cli-session-arguments-tests`; remote transfer intentionally waits for the machine/repository packages. Valid invocations fail explicitly before local runtime/Git effects. Reference: `src/cli/worktree.zig:65`, `worktree_dispatch.zig`. |
| `worktree list` | done | Same comparison: empty/tracked/untracked text and JSON, diff/command/agent projection, no adoption while listing; `cli-sessions-tests`. Source: `src/cli/worktree.zig:263`, `worktree.zig:676`. Agent JSON formatting follows `src/cli/control.zig:161`. |
| `worktree open` | done | Real-GUI comparison: explicit client and most recently used client, plus no-client/missing-worktree failures. Source: `src/cli/worktree.zig:445`. `cli-sessions-tests` retains failures without requiring a GUI. |
| `worktree remove` | partial | Local comparison: clean/dirty removal, force refusal without a terminal, merged branch deletion, unmerged branch refusal and keeping the branch; `cli-sessions-tests`. Source: `src/cli/worktree.zig:491`. Safe fallback: Git without `--no-lazy-fetch` cannot pass the hardened merge check, so deletion asks for terminal confirmation even if merged (older-Git path not compared). |
| `worktree resolve` | done | `check_sessions_cli.py`: open/closed workspaces, explicit paths, origin matching and failure diagnostics; `cli-sessions-tests` retains the history lookup. Source: `src/cli/worktree.zig:535`, `repository_discovery.zig:19`. `session_history_paths.hpp` opens SQLite read-only through a lazy loader only for resolve: no SQLite startup dependency for hooks. Linux without available dynamic-loader symbols fails explicitly with `RepositoryHistoryUnavailable` (not compared on this Mac). |
| `agent acknowledge` | done | Stack comparison matches Zig; CTest covers ordering barrier, updated status and unapplied acknowledgements. Reference: `src/cli/agent.zig:86`. |
| `agent get` | done | Stack comparison: ids, case-insensitive/UTF-8 titles, missing agent/worktree, exact rows/JSON match Zig; CTest also checks ambiguity and worktree branch/title resolution. Reference: `src/cli/Snapshot.zig:26`, `src/cli/control.zig:161`. |
| `agent interrupt` | done | Stack comparison matches Zig; CTest verifies request and returned pre-interrupt snapshot. Reference: `src/cli/agent.zig:105`. |
| `agent list` | done | Stack comparison matches Zig; CTest preserves all JSON fields, session id, plan and final message. Reference: `src/cli/agent.zig:229`, `src/cli/control.zig:161`. |
| `agent prompt` | done | Stack comparison: blocked/ready prompts and wait timeout match Zig. CTest: start/completion/failure, interrupt settling, generation changes, sender attribution, focus/rate refusals and text limits. Reference: `src/cli/agent.zig:156`, `src/cli/control.zig:41`. |
| `agent read` | partial | Same C++ runtime final-space difference as `pane read`; CLI output and errors covered by stack comparison and CTest. Reference: `src/cli/agent.zig:119`, `src/cli/agent.zig:260`. |
| `agent report-command` | done | Stack comparison and CTest match Zig using the protocol reports shared with hooks. Includes Zig's `WorktreeCatalogMissing` for a worktree target. Reference: `src/cli/AgentReports.zig:18`, `src/cli/arguments/AgentOptions.zig:66`. |
| `agent report-session` | done | Stack comparison and CTest: session validation, silent success and failures match Zig. Reference: `src/cli/agent.zig:111`, `src/core/schema/messages/agent.zig:37`. |
| `agent report-state` | done | Stack comparison and CTest: lifecycle, reason/event/session validation and accepted JSON match Zig; hook protocol types reused. Worktree report keeps Zig's `WorktreeCatalogMissing`. Reference: `src/cli/AgentReports.zig:18`. |
| `agent report-title` | done | Stack comparison and CTest: empty/UTF-8 title, validation, current generation and accepted JSON match Zig; hook report type reused. Worktree report keeps Zig's `WorktreeCatalogMissing`. Reference: `src/cli/AgentReports.zig:18`. |
| `agent wait` | done | Stack comparison: ready/idle and timeout diagnostics/status 3 match Zig; CTest checks polling and missing targets. Reference: `src/cli/agent.zig:131`, `src/cli/arguments/values.zig:103`. |
| `exec cancel` | done | `check_exec_runtime_cli.py`: cancellation and retained status; `exec-runtime-cli-tests`. |
| `exec forget` | done | Same check: refuses a running execution, forgets an exited one, subsequent status fails with 125. |
| `exec list` | done | Same check: retained executions, JSON without requiring `--json`. |
| `exec output` | done | Same check: binary stdout/stderr, offsets, retention loss and recovery. |
| `exec start` | partial | Same check: raw binary stdin/stdout/stderr, child status, spawn failure, timeout, retry identity. Native runtime initially replies `running`; Zig replies `starting` for detached starts. |
| `exec status` | done | Same check: JSON fields, failed/missing/cancelled executions and status after timeout. |
| `repository prepare` | partial | Source preparation and the `exec`/receive pipeline pass `repository-prepare-probe` in `exec-runtime-cli-tests`. The public CLI delegates profile resolution/dispatch to package 5 (`machine list --json`, `--machine`), still missing on this branch; real SSH comparison pending. See `exec-runtime.md`. |
| `repository receive` | done | `check_exec_runtime_cli.py`: verified bundle, publication, dirty clone reuse, explicit selection, closed-workspace history discovery, ambiguity, interrupted/long/mismatched transfer, unowned stage. |
| `project setup` | done | Same check: absent/invalid recipe, successful recipe, stderr streams, detach and failed exit. `project_setup::prepare` is reusable by worktree create. |
| `file get` | done | Same check: 131,334 binary bytes including every byte value; ownership/link/type refusals. `exec-runtime-offline-tests`. |
| `file put` | done | Same check: byte-exact publication, private permissions, empty input, short/long input, occupied destination and ancestor symlink refusal. |
| `machine add` | done | `check_machines_launch.py`; private file bytes/modes, validation, duplicate fields, check-before-save, setup and isolated SSH. |
| `machine check` | done | Zig/C++ success, schema mismatch, missing telar, host-key/auth/runtime failures; real discovery during isolated localhost setup. |
| `machine disable` | done | `check_machines_launch.py`; retained by `machines-launch-cli-tests`. |
| `machine enable` | done | `check_machines_launch.py`; retained by `machines-launch-cli-tests`. |
| `machine list` | done | `check_machines_launch.py`: exact text/JSON, local label, v1/v2 profiles, login fields and insecure/malformed files. |
| `machine receive-config` | done | `check_machines_launch.py`, `check_machine_setup.py`: stream bounds/modes, denied paths, symlink refusal, changed/unchanged files; real SSH stdin transfer. |
| `machine remove` | done | `check_machines_launch.py`; retained by `machines-launch-cli-tests`. |
| `machine rename` | done | `check_machines_launch.py`: same-name no-op, reserved local label and collision refusal. |
| `machine setup` | partial | `check_machine_setup.py`: configuration filtering and login lifecycle match Zig; real localhost upload/idempotence/repair and GUI attachment. Interactive provider OAuth and released C++ archives remain unverified. Login commands require the other ports of workspace/tab/pane; C++ deployment carries CLI/module/runtime and hashes all three (see port report). |
| `client clipboard` | unverified | CLI wire/output matches; host clipboard effect not compared. [Window checks](window-port.md). |
| `client copy-mode` | partial | Fresh entry matches; GUI admits over history where Zig returns `CopyModeUnavailable`. [Window checks](window-port.md). |
| `client detach` | done | Real runtime/GUI and exact CLI fixtures; [window checks](window-port.md). |
| `client get` | done | Real runtime/GUI and exact CLI fixtures; [window checks](window-port.md). |
| `client list` | done | Empty and attached real runtimes, text/JSON fixtures; [window checks](window-port.md). |
| `client open` | partial | Goto fixtures and fresh history match; GUI history admits over another prompt where Zig refuses. [Window checks](window-port.md). |
| `client open-link` | unverified | Wire/output and real invalid-URI rejection match; host browser/editor effect not compared. [Window checks](window-port.md). |
| `sidebar get` | done | Real GUI state and exact text/JSON fixtures; [window checks](window-port.md). |
| `sidebar hide` | done | Real GUI mutation/readback and fixtures; [window checks](window-port.md). |
| `sidebar resize` | done | Common host geometry clamp and exact fixtures; [window checks](window-port.md). |
| `sidebar show` | done | Real GUI mutation/readback and fixtures; [window checks](window-port.md). |
| `workspace-list collapse` | done | Real GUI mutation and exact fixtures; [window checks](window-port.md). |
| `workspace-list expand` | done | Real GUI mutation and exact fixtures; [window checks](window-port.md). |
| `layout apply` | partial | Valid token applies; invalid-token GUI diagnostic differs (`InvalidLength` in Zig). [Window checks](window-port.md). |
| `layout get` | done | Real GUI token matches byte-for-byte; text/JSON fixtures. [Window checks](window-port.md). |
| `notification dismiss` | done | Real owned first toast dismissed, repeated/stale id refused; exact fixtures. [Window checks](window-port.md). |
| `notification show` | done | Real delivery/no clients, UTF-8 title/body clipping, limit reports and fixtures. [Window checks](window-port.md). |
| `command suggest` | done | All four statuses and output fixtures; real runtime without an engine. [Window checks](window-port.md). |
| `config check` | partial | C++ companion validates Lua/plugins/keymaps; 12/13 config cases match, nested diagnostic paths differ. [Window checks](window-port.md). |
| `config reload` | done | Real GUI admission/adoption and exact fixtures; [window checks](window-port.md). |
| `config show` | done | All six real GUI sections, pretty/minified JSON and decimal-number fixtures; [window checks](window-port.md). |
| `plugin disable` | partial | Override adoption matches; GUI clears admitted `text` that Zig retains. [Window checks](window-port.md). |
| `plugin enable` | partial | Override adoption matches; GUI clears admitted `text` that Zig retains. [Window checks](window-port.md). |
| `plugin get` | done | Real configured package and generation-bound paginated fixtures; [window checks](window-port.md). |
| `plugin inspect` | unverified | Implemented; no Zig comparison yet. |
| `plugin install` | unverified | Implemented; no Zig comparison yet. |
| `plugin list` | done | Real configured/disabled packages and paginated fixtures; [window checks](window-port.md). |
| `plugin run` | partial | Real no-op worker admitted; GUI clears admitted `text` that Zig retains. [Window checks](window-port.md). |
| `plugin trust` | unverified | Implemented; no Zig comparison yet. C++ also has `plugin untrust ID`, which Zig lacks. |
| `integration install` | done | `check_integration.py`: all 68 scenarios match including stderr, files, permissions and skills/extensions; hooks prefer TELAR_BIN_PATH. `integration-tests` retains the exact command contract. |
| `integration status` | done | Same 68 lifecycle comparisons as install, including stderr. |
| `integration uninstall` | done | Same 68 lifecycle comparisons as install, including stderr. |
| `hook` | done | 324 `check_hook_cli.py`, 14 `check_hook_worktrees.py` and 8 `check_hook_registration.py` cases match Zig. With a null `cwd`, worktree hooks fail closed where Zig creates the checkout (`check_hook_null_paths.py`, deliberate). |
| `cli install` | done | `check_machines_launch.py`: exact link target, replacement/idempotence, foreign-file refusal and missing-parent errors; isolated directories only. |
| `cli status` | done | `check_machines_launch.py`: missing link, existing link and regular-file errors. |
| `cli uninstall` | done | `check_machines_launch.py`: existing/missing links and regular-file refusal. |
| `gui` | done | `check_window_parity.py`: real windows stack against stack; `check_window_launch.py`: login shell, options, bundle/sibling resolution and runtime survival; real saved-machine GUI launch over localhost SSH. |
| `server` | done | Runs the runtime by exec'ing the `telar-runtime` beside `telar`; `server-cli-tests`. |
| `server bridge` | done | Hidden; `server-cli-tests`. |
| `server endpoint` | done | Starts `telar-runtime server --daemonized` when none runs; `server-cli-tests`. |
| `server stop` | done | `server-cli-tests`. |
| `runtime metrics` | done | Same check: deterministic metric frames, text/JSON, battery present/absent; live samples separately validate ranges. |
| `runtime status` | done | Same check: text/JSON, unavailable runtime and deterministic port warning. Reports native `cqp00001`, deliberately unlike Zig. |
| `runtime watch` | done | Same check: fixed proxy/metrics/workspace/agent snapshots, count, stopping and resync; live subscription also exercised. |
| `diagnostics limits` | partial | Same check: empty/reached registries, JSON/text and client import limit. Native runtime does not report `executions.retained_bytes`, unlike Zig; CLI prints the registry it receives. |
| `diagnostics logs` | done | Same check: sorted telemetry/runtime/start logs, text/JSON tails, component/pid filters, missing logs, safe file checks and standard JSON escaping. |
| `history delete` | done | Same check: exact retained entry removed. |
| `history import` | done | Same check: zsh continuations, bash/fish timestamps, idempotency, oversized-command skip, 64-entry and payload batch boundaries. CTest needs no Zig. |
| `history list` | done | Same check: default/explicit limit, escaped fields, cwd/pane/failed filters and empty result. |
| `history prune` | done | Same check: preview, date notice, dry run, abort, confirmed/--yes deletion and text filter. |
| `history search` | done | Same check: imported commands and retained commands after a limit. |
| `history show` | done | Same check: raw captured bytes, truncation notice and the no-output notice on stderr. |
| `history stats` | partial | Same check: totals, unique count, periods and grouping. Native runtime sorts tied top groups alphabetically; Zig preserves hash iteration order. |
| `proxy trust` | unverified | Implemented; `check_proxy_trust.py` needs a `tls-probe` the runtime no longer builds. |
| `proxy watch` | done | Same check: subscription filtering, count, stopping; observer never starts a runtime. |
| `api schema` | done | `exec-runtime-offline-tests` checks every native tag against the C++ declarations; comparison checks shared Zig tags/bounds. Native ID/fingerprint and clipboard extensions intentionally differ; see `exec-runtime.md`. |

## Building blocks

- `main.cpp` dispatches on `Family` (`family.hpp`); a family's case calls its
  `run` function and returns the exit status. Throw `std::invalid_argument` for
  usage errors: `main` adds the help reference.
- `help.hpp` finds and prints help before any command runs; commands never
  handle `--help` themselves.
- `ControlSession` (`control_session.hpp`) is the request/reply conversation
  with the runtime; a refusal arrives as `ControlFailure`, whose text is Zig's
  `control.describe`. Print it as `telar FAMILY: TEXT`.
- `RuntimePaths` (`telar_platform/runtime_paths.hpp`) resolves `--socket`,
  `TELAR_SOCKET` and `TELAR_SOCKET_PATH` as Zig does; `server endpoint`
  (`server.hpp`) starts the runtime beside `telar` when none runs.
- `appendJsonText` (`json_text.hpp`) writes JSON strings with the escaping the
  Zig command used: `standard` where it used std.json.Stringify, `control`
  where it used control.writeJsonString.
- Code the runtime or the GUI also needs belongs in `dlls/`, never included
  from `services/runtime-cpp` or `services/gui-cpp`.
