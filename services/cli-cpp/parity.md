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
| `worktree create` | partial | Local stack comparison covers checkout, duplicate rejection, default source workspace, alias, setup authorization, recipes, symlink refusal and effects; `cli-sessions-tests`. Source: `src/cli/worktree.zig:129`, `project_setup.zig:33`. `--machine` dispatch remains pending the machine/repository ports; it fails explicitly without running Git or starting a local runtime. |
| `worktree diff` | done | Same comparison: base/uncommitted diff, diffstat, empty diff and adopting an untracked linked checkout; `cli-sessions-tests`. Source: `src/cli/worktree.zig:479`, `worktree_git.zig:221`. |
| `worktree exec` | done | Same comparison: branch/title lookup (case insensitive titles), background launch, literal argv, wait text/JSON, nonzero exit and timeout (pane remains running); `cli-sessions-tests`. Source: `src/cli/worktree.zig:200`, `lib/pty/login_shell.zig:69`. |
| `worktree fetch` | partial | Argument grammar/validation ported and compared by `cli-session-arguments-tests`; remote transfer intentionally waits for the machine/repository packages. Valid invocations fail explicitly before local runtime/Git effects. Reference: `src/cli/worktree.zig:65`, `worktree_dispatch.zig`. |
| `worktree list` | done | Same comparison: empty/tracked/untracked text and JSON, diff/command/agent projection, no adoption while listing; `cli-sessions-tests`. Source: `src/cli/worktree.zig:263`, `worktree.zig:676`. Agent JSON formatting follows `src/cli/control.zig:161`. |
| `worktree open` | done | Real-GUI comparison: explicit client and most recently used client, plus no-client/missing-worktree failures. Source: `src/cli/worktree.zig:445`. `cli-sessions-tests` retains failures without requiring a GUI. |
| `worktree remove` | partial | Local comparison: clean/dirty removal, force refusal without a terminal, merged branch deletion, unmerged branch refusal and keeping the branch; `cli-sessions-tests`. Source: `src/cli/worktree.zig:491`. Safe fallback: Git without `--no-lazy-fetch` cannot pass the hardened merge check, so deletion asks for terminal confirmation even if merged (older-Git path not compared). |
| `worktree resolve` | done | `check_sessions_cli.py`: open/closed workspaces, explicit paths, origin matching and failure diagnostics; `cli-sessions-tests` retains the history lookup. Source: `src/cli/worktree.zig:535`, `repository_discovery.zig:19`. `session_history_paths.hpp` opens SQLite read-only through a lazy loader only for resolve: no SQLite startup dependency for hooks. Linux without available dynamic-loader symbols fails explicitly with `RepositoryHistoryUnavailable` (not compared on this Mac). |
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
