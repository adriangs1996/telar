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
| `machine add` | missing |  |
| `machine check` | missing |  |
| `machine disable` | missing |  |
| `machine enable` | missing |  |
| `machine list` | missing |  |
| `machine receive-config` | missing |  |
| `machine remove` | missing |  |
| `machine rename` | missing |  |
| `machine setup` | missing |  |
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
