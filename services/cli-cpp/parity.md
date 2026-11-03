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
| `exec cancel` | missing |  |
| `exec forget` | missing |  |
| `exec list` | missing |  |
| `exec output` | missing |  |
| `exec start` | missing |  |
| `exec status` | missing |  |
| `repository prepare` | missing |  |
| `repository receive` | missing |  |
| `project setup` | missing |  |
| `file get` | missing |  |
| `file put` | missing |  |
| `machine add` | done | `check_machines_launch.py`; private file bytes/modes, validation, duplicate fields, check-before-save, setup and isolated SSH. |
| `machine check` | done | Zig/C++ success, schema mismatch, missing telar, host-key/auth/runtime failures; real discovery during isolated localhost setup. |
| `machine disable` | done | `check_machines_launch.py`; retained by `machines-launch-cli-tests`. |
| `machine enable` | done | `check_machines_launch.py`; retained by `machines-launch-cli-tests`. |
| `machine list` | done | `check_machines_launch.py`: exact text/JSON, local label, v1/v2 profiles, login fields and insecure/malformed files. |
| `machine receive-config` | done | `check_machines_launch.py`, `check_machine_setup.py`: stream bounds/modes, denied paths, symlink refusal, changed/unchanged files; real SSH stdin transfer. |
| `machine remove` | done | `check_machines_launch.py`; retained by `machines-launch-cli-tests`. |
| `machine rename` | done | `check_machines_launch.py`: same-name no-op, reserved local label and collision refusal. |
| `machine setup` | partial | `check_machine_setup.py`: configuration filtering and login lifecycle match Zig; real localhost upload/idempotence/repair and GUI attachment. Interactive provider OAuth and released C++ archives remain unverified. Login commands require the other ports of workspace/tab/pane; C++ deployment carries CLI/module/runtime and hashes all three (see port report). |
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
| `runtime metrics` | missing |  |
| `runtime status` | missing |  |
| `runtime watch` | missing |  |
| `diagnostics limits` | missing |  |
| `diagnostics logs` | missing |  |
| `history delete` | missing |  |
| `history import` | missing |  |
| `history list` | missing |  |
| `history prune` | missing |  |
| `history search` | missing |  |
| `history show` | missing |  |
| `history stats` | missing |  |
| `proxy trust` | unverified | Implemented; `check_proxy_trust.py` needs a `tls-probe` the runtime no longer builds. |
| `proxy watch` | missing |  |
| `api schema` | missing |  |

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
