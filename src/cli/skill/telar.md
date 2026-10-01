# Driving telar from an agent

telar is the runtime your pane lives on. It owns the terminals, sees every
agent's state, and exposes a small CLI you can call from any pane. Every pane
child receives `TELAR_SOCKET_PATH`, `TELAR_PANE_ID`, `TELAR_WORKSPACE_ID` and
`TELAR_TAB_ID`; `--current` resolves to your own pane through them.

## Commands

```
telar agent list [--json]
telar agent get <target> [--json]
telar agent wait <target> [--until done|finished|ready|blocked|working|failed] [--timeout 30s]
telar agent prompt <target> "text" [--interrupt] [--wait] [--timeout 30s] [--json]
telar agent interrupt <target> [--json]
telar agent read <target> [--lines 40] [--source recent|screen] [--json]
telar agent report-session <pane|--current> <session-id>
telar pane read <pane|--current> [--lines 40] [--source recent|screen] [--json]
telar pane send-keys <pane|--current> "text" [--enter]
telar tab create --background [--workspace <id>] [--label name] [--json]
telar api schema [--json]
telar worktree create <branch> --title "title" [--from <ref>] [--workspace <id|dir>] [--json] [-- <command...>]
telar worktree exec <branch> [--label name] [--json] -- <command...>
telar worktree list [--workspace <id|dir>] [--json]
telar worktree open <branch> [--client ID]
telar worktree diff <branch> [--stat] [--uncommitted]
telar worktree remove <branch> [--force] [--delete-branch]
telar worktree create <branch> --machine <label> --title "title" [--from <ref>] [--json] [-- <command...>]
telar worktree fetch <branch> --machine <label> [--json]
telar machine list [--json]
telar --machine <label> <any command above>
telar --skill [coordinator]
telar integration install|uninstall|status claude|codex|pi|cursor|opencode
```

A `<target>` is a pane's numeric id, its agent's session title
(case-insensitive, must be unique), `--current`, or `worktree:<branch|title>`
for the agent working in a tracked worktree. To coordinate agents in
worktrees, read `telar --skill coordinator`.

## Machines

`telar machine list --json` names the machines the user saved, and this one.
`telar --machine <label> <command>` runs any command on that machine's
runtime and returns its output and exit code; the label of this machine runs
it here. A failure there is a failure: nothing falls back to this machine.
`--machine` is never inherited: pass it on every command meant for another
machine.

`telar worktree create <branch> --machine <label>` pushes the branch's commits
to that machine's clone of this repository and creates the worktree there.
Only commits travel; uncommitted files stay here. `telar worktree fetch
<branch> --machine <label>` brings the branch back as
`refs/remotes/<label>/<branch>`.

## Agent states

- `working`: the agent is executing or waiting on a model.
- `blocked`: it is showing an approval, question or permission prompt. A
  prompt sent now is refused; answer with `pane send-keys` first.
- `done`: it finished a turn and no user has looked at the pane yet.
  `--until finished` accepts `done` or `ready`.
- `ready`: it is idle and its last result has been seen.
- `failed`: its last model request failed.

## Rules

1. `agent prompt` sends the text as one paste followed by Enter and returns
   immediately. Add `--wait` to block until the agent finishes or blocks;
   exit code 3 means it never started working or timed out. telar encodes
   Enter the way the agent's keyboard mode reads it. `pane send-keys
   --enter` presses Enter 150 ms after the text, so an agent that reads fast
   typing as a paste still submits it.
2. `agent interrupt` presses the agent's own interrupt key (Ctrl+C for
   Claude Code, Escape twice for OpenCode, Escape for the others). The agent
   stays `working` until its screen shows the idle prompt, its integration
   reports, or, for OpenCode and Pi without an integration, 3 s pass.
   `agent prompt --interrupt` waits up to 15 s for that before it sends the
   new prompt, and fails if the turn does not stop. Interrupting again 2 s
   or more after the last press presses the key again. When Claude Code
   puts the unanswered prompt back in its composer, telar clears it first.
3. `agent wait` polls the runtime; it never guesses. `--timeout` takes up
   to a day (86400s), so one wait covers a long build. Exit codes: 0
   reached, 2 the agent or pane is gone, 3 timed out.
4. `agent read` and `pane read` return a plain-text snapshot of the most
   recent rows (`--source recent`, default) or the visible screen.
   `--lines N` counts up from the last row that shows text, so the blank
   rows below a short output never hide it. `--lines` takes up to 2000 and a
   read carries up to 256 KiB, keeping the newest lines; `truncated`
   in JSON output means older rows were dropped. A finished command
   (`exec --wait`, or a read after its pane exited) keeps its last 200 rows
   within 16 KiB; `truncated` there also means it printed more than that.
5. Nothing here changes layout or focus; those belong to the user's client.
6. `agent report-session` stores your own session id with your pane. After a
   runtime restart, telar relaunches the pane's shell and types the resume
   command for it (`claude --resume`, `codex resume`, `pi --session`, `cursor-agent --resume`,
   `opencode --session`). Agent hooks report the
   `session_id` they receive through the same runtime request.

## Orchestrating

```sh
telar agent prompt 7 "Run the test suite and summarize failures" --wait
telar agent read 7 --lines 60
telar agent wait 9 --until blocked --timeout 120s && telar pane send-keys 9 y --enter
```

## Raw execution and preparation

Use `telar exec -- PROGRAM ARGS...` for runtime-owned work without a terminal.
Stdin/stdout/stderr preserve bytes separately; argv is literal. Default cwd is
this destination's HOME, independent of GUI focus. `--cwd ABS` and `--workspace ID`
are explicit destination-local selections. `--detach --json` returns an execution
ID. `exec list`, `exec status ID`, `exec output ID`, `exec cancel ID` and
`exec forget ID` observe and release results. Disconnect/timeout closes stdin
without cancelling. Results last for one runtime lifetime; 32 results and a
1 MiB tail per stream are retained. Lost output is reported, never presented as
complete. Foreground child streams contain no metadata; discover IDs with list.

For another saved machine prefix commands with `telar --machine LABEL`.
`repository prepare --machine LABEL --from HEAD --json` transfers committed Git
history from here, without copying provider credentials. Remote worktree create
calls preparation automatically. A declared `.telar/setup.json` recipe needs
`--setup` on create, or explicit `project setup --cwd ABS`; failure starts no
agent. `file put ABS --bytes N` reads an artifact from stdin and publishes without
overwrite; `file get ABS` writes its bytes. Use raw exec for runtime-owned transfer,
never terminal screen text. Read `telar --skill coordinator` for the complete
prepare/setup/brief/agent/fetch flow. Codex examples use `codex --no-daemon`.
