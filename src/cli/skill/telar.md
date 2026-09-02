# Driving telar from an agent

telar is the runtime your pane lives on. It owns the terminals, sees every
agent's state, and exposes a small CLI you can call from any pane. Every pane
child receives `TELAR_SOCKET_PATH`, `TELAR_PANE_ID`, `TELAR_WORKSPACE_ID` and
`TELAR_TAB_ID`; `--current` resolves to your own pane through them.

## Commands

```
telar agent list [--json]
telar agent get <pane|title|--current> [--json]
telar agent wait <pane|title|--current> [--until done|ready|blocked|working|failed] [--timeout 30s]
telar agent prompt <pane|title|--current> "text" [--wait] [--timeout 30s]
telar agent read <pane|title|--current> [--lines 40] [--source recent|screen] [--json]
telar agent report-session <pane|--current> <session-id>
telar pane read <pane|--current> [--lines 40] [--source recent|screen] [--json]
telar pane send-keys <pane|--current> "text" [--enter]
telar api schema [--json]
telar --skill
telar integration install|uninstall|status claude
```

A pane is named by its numeric id, its agent's session title (case-insensitive,
must be unique) or `--current`.

## Agent states

- `working`: the agent is executing or waiting on a model.
- `blocked`: it is showing an approval, question or permission prompt. A
  prompt sent now is refused; answer with `pane send-keys` first.
- `done`: it finished a turn and no user has looked at the pane yet.
- `ready`: it is idle and its last result has been seen.
- `failed`: its last model request failed.

## Rules

1. `agent prompt` sends the text as one paste followed by Enter and returns
   immediately. Add `--wait` to block until the agent finishes or blocks;
   exit code 3 means it never started working or timed out.
2. `agent wait` polls the runtime; it never guesses. Exit codes: 0 reached,
   2 the agent or pane is gone, 3 timed out.
3. `agent read` and `pane read` return a plain-text snapshot of the most
   recent rows (`--source recent`, default) or the visible screen. Text is
   bounded; `truncated` in JSON output means older rows were dropped.
4. Nothing here changes layout or focus; those belong to the user's client.
5. `agent report-session` stores your own session id with your pane. After a
   runtime restart, telar relaunches the pane's shell and types the resume
   command for it (`claude --resume`, `codex resume`). Agent hooks report the
   `session_id` they receive through the same runtime request.

## Orchestrating

```sh
telar agent prompt 7 "Run the test suite and summarize failures" --wait
telar agent read 7 --lines 60
telar agent wait 9 --until blocked --timeout 120s && telar pane send-keys 9 y --enter
```
