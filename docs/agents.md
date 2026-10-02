# Working with agents

Install and authenticate your chosen agent CLI first. Telar runs that CLI in
a terminal pane; Telar's integration does not create a provider account or
supply API access. This guide assumes `telar` is [on your PATH](usage.md#put-telar-on-your-path).

## Install an integration

Choose the row for the agent you use. Run the install command, then launch a
new agent session inside a Telar pane.

| Agent | Install integration | Launch inside Telar |
| --- | --- | --- |
| Claude Code | `telar integration install claude` | `claude` |
| Codex | `telar integration install codex` | `codex --no-daemon` |
| Pi | `telar integration install pi` | `pi` |
| Cursor Agent | `telar integration install cursor` | `cursor-agent` |
| OpenCode | `telar integration install opencode` | `opencode` |

Integrations add hooks or a Telar extension/plugin in the agent's configuration.
They report lifecycle events and supported shell-tool calls. The Codex flag
keeps the session and hooks attached to the correct pane instead of a shared
daemon. Run the installation from the Telar executable you intend to keep;
hooks contain its path. Repeat installation after moving that executable.

For example, inspect or remove the Claude integration with:

```sh
telar integration status claude
telar integration uninstall claude
```

Use the same agent name as on installation. Status reports integration files;
it does not prove that a running session has loaded them. Restart that agent
session and check its entry in `telar agent list --json`.

## Read an agent's status

Open the sidebar with `Ctrl+b` then `s`. Click an agent to navigate to its
pane, including when it is in another tab or workspace. Run this to inspect
states from a shell:

```sh
telar agent list --json
```

| State | Meaning |
| --- | --- |
| `working` | The agent is executing or waiting for its model. |
| `blocked` | It needs input, such as a permission decision or answer. Read its pane before responding. |
| `done` | A turn finished and its result has not yet been acknowledged. This is not proof that its task or tests succeeded. |
| `ready` | The agent is idle and has no unseen completed turn. |
| `failed` | Telar observed a failure. Inspect the agent's output for the cause. |
| `unknown` | Telar does not have enough evidence to classify the current state. |

Without hooks, process and screen observations provide best-effort status.
Not every provider reports the same details. `final_message` may be empty or
shortened; inspect the actual output and diff before accepting a result.

## Give a task its own worktree

Run the following inside an existing Git project with at least one commit.
Use a new branch name and a task you actually want the agent to perform:

```sh
telar worktree create fix-tests --title "Fix failing tests" --json -- claude
```

Telar creates a checkout on `fix-tests` and launches Claude there. The JSON
identifies the checkout path and pane. Open it to review workspace trust,
authentication or other startup questions in the agent's own interface:

```sh
telar worktree open fix-tests
```

Submit your task in that pane. Describe the desired result, constraints and
how to verify it; a new session does not inherit another agent's conversation.
The worktree starts from committed history. Uncommitted files in your original
checkout are not copied. Use `--from REF` to choose another starting commit.

Inspect progress and changes from another pane:

```sh
telar worktree list --json
telar worktree diff fix-tests --stat
telar worktree diff fix-tests
```

You can run a command in a new terminal tab of that worktree, for example:

```sh
telar worktree exec fix-tests --wait -- git status --short
```

`--wait` waits for that command, prints retained terminal output and returns
the command's exit status. Add `--json` to include `exit_code` and `truncated`
in the response. It is not an unlimited build log. For raw stdout/stderr and
commands that need no terminal, use
`telar exec --no-stdin --cwd ABSOLUTE_WORKTREE_PATH -- PROGRAM`.

## Control an agent from another pane

`worktree:fix-tests` targets the agent in that worktree. Pane IDs from
`agent list` also work; never assume the example's branch or a numeric ID
exists in another runtime.

```sh
telar agent get worktree:fix-tests --json
telar agent read worktree:fix-tests --lines 60
telar agent wait worktree:fix-tests --until finished --timeout 600s --json
```

`finished` accepts both `done` and `ready`. A timeout exits with status 3 and
does not stop the agent. Waiting for `finished` on an already idle session
returns immediately; it does not submit work.

To submit a follow-up to an idle, unfocused agent:

```sh
telar agent prompt worktree:fix-tests "Summarize the changes and tests you ran" --wait --timeout 600s --json
```

Inspect the returned status: `blocked` means the agent needs a decision, not
that the task is complete. Prompting a pane focused in a window is refused
because a person may be typing there; focus another pane first. Read and answer
approval dialogs yourself. Do not turn every `blocked` event into an automatic
`y` response.

To stop the current turn while leaving the session open:

```sh
telar agent interrupt worktree:fix-tests
```

Review and integrate the branch through your normal Git workflow. Once the
work is saved and the worktree has no local changes, remove its checkout:

```sh
telar worktree remove fix-tests
```

This closes its tabs and keeps the branch. Add `--delete-branch` only when you
also want the branch deleted. Unmerged branch deletion requires confirmation;
`--force` discards local changes and is not routine cleanup.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| No agent entry | Launch the agent inside a Telar pane; inspect `telar pane list --json` and the actual process. |
| State or history is missing | Check integration status, restart the agent, and inspect its own hook/extension errors. |
| Codex reports the wrong pane | Start a new session with `codex --no-daemon`. |
| `pane_focused` | Move the window's focus to a different pane before sending a prompt. |
| `agent_blocked` | Open/read the agent pane and resolve the specific question. |
| Wait times out | Read the agent's output; timeout does not mean cancellation or permission to launch a duplicate. |

For remote tasks, continue with [remote machines](remote.md). For automated
delegation, ask your agent to read `telar --skill coordinator`. Implementation
details live in [agent hooks](flows/agent-hooks.md) and
[agent control](flows/agent-control.md).
