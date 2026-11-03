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
| `telar --skill [telar\|coordinator]` | done | Embedded from `src/cli/skill`. |
| `telar` with no arguments, `telar COMMAND...` | missing | Opens a window running a shell or COMMAND. |
| `--config`, `--no-config`, `--profile`, `--theme`, `--fresh`, `--remote` before COMMAND | missing | Window options. |
| `telar --machine LABEL ...`, `dispatch-argv` | missing | Runs one command on a saved machine over SSH. |
| `plugin-worker` | forwarded | `telar` exec's `telar-runtime plugin-worker`; the worker belongs to the runtime. |
| Usage errors | partial | `main` prints Zig's format, `telar: MESSAGE; see \`telar FAMILY [COMMAND] --help\``, exit 1; each family still has to use Zig's messages. |

## Commands

| Command | Status | Notes |
| --- | --- | --- |
| `workspace create` | missing |  |
| `workspace get` | missing |  |
| `workspace list` | missing |  |
| `workspace rename` | missing |  |
| `workspace select` | missing |  |
| `tab close` | missing |  |
| `tab create` | missing |  |
| `tab get` | missing |  |
| `tab list` | missing |  |
| `tab move` | missing |  |
| `tab next` | missing |  |
| `tab previous` | missing |  |
| `tab rename` | missing |  |
| `tab select` | missing |  |
| `pane close` | missing |  |
| `pane copy` | missing |  |
| `pane create` | missing |  |
| `pane focus` | missing |  |
| `pane fullscreen` | missing |  |
| `pane get` | missing |  |
| `pane list` | missing |  |
| `pane read` | missing |  |
| `pane resize` | missing |  |
| `pane scroll` | missing |  |
| `pane search` | missing |  |
| `pane send-keys` | missing |  |
| `pane split` | missing |  |
| `pane watch` | missing |  |
| `worktree create` | missing |  |
| `worktree diff` | missing |  |
| `worktree exec` | missing |  |
| `worktree fetch` | missing |  |
| `worktree list` | missing |  |
| `worktree open` | missing |  |
| `worktree remove` | missing |  |
| `worktree resolve` | missing |  |
| `agent acknowledge` | missing |  |
| `agent get` | missing |  |
| `agent interrupt` | missing |  |
| `agent list` | missing |  |
| `agent prompt` | missing |  |
| `agent read` | missing |  |
| `agent report-command` | missing |  |
| `agent report-session` | missing |  |
| `agent report-state` | missing |  |
| `agent report-title` | missing |  |
| `agent wait` | missing |  |
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
| `machine add` | missing |  |
| `machine check` | missing |  |
| `machine disable` | missing |  |
| `machine enable` | missing |  |
| `machine list` | missing |  |
| `machine receive-config` | missing |  |
| `machine remove` | missing |  |
| `machine rename` | missing |  |
| `machine setup` | missing |  |
| `client clipboard` | missing |  |
| `client copy-mode` | missing |  |
| `client detach` | missing |  |
| `client get` | missing |  |
| `client list` | missing |  |
| `client open` | missing |  |
| `client open-link` | missing |  |
| `sidebar get` | missing |  |
| `sidebar hide` | missing |  |
| `sidebar resize` | missing |  |
| `sidebar show` | missing |  |
| `workspace-list collapse` | missing |  |
| `workspace-list expand` | missing |  |
| `layout apply` | missing |  |
| `layout get` | missing |  |
| `notification dismiss` | missing |  |
| `notification show` | missing |  |
| `command suggest` | missing |  |
| `config check` | missing |  |
| `config reload` | missing |  |
| `config show` | missing |  |
| `plugin disable` | missing |  |
| `plugin enable` | missing |  |
| `plugin get` | missing |  |
| `plugin inspect` | unverified | Implemented; no Zig comparison yet. |
| `plugin install` | unverified | Implemented; no Zig comparison yet. |
| `plugin list` | missing |  |
| `plugin run` | missing |  |
| `plugin trust` | unverified | Implemented; no Zig comparison yet. C++ also has `plugin untrust ID`, which Zig lacks. |
| `integration install` | partial | `check_integration.py`: 32 of 68 cases differ from Zig in the files written (skills/extension set). |
| `integration status` | partial | Same file-set differences as `install`. |
| `integration uninstall` | partial | Same file-set differences as `install`. |
| `hook` | done | 324 `check_hook_cli.py`, 14 `check_hook_worktrees.py` and 8 `check_hook_registration.py` cases match Zig. With a null `cwd`, worktree hooks fail closed where Zig creates the checkout (`check_hook_null_paths.py`, deliberate). |
| `cli install` | missing |  |
| `cli status` | missing |  |
| `cli uninstall` | missing |  |
| `gui` | missing |  |
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
