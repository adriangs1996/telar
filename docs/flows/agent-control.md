# Agent control

Agents and scripts drive the runtime through `telar agent` and `telar pane`.
The CLI is a control client: it speaks the same framed schema as the UI over
the same socket, holds no attachment, and receives only what it asks for.

## End-to-end path

```text
telar agent wait 7 --until done
        |
cli.control.Session.open  (--socket, TELAR_SOCKET, TELAR_SOCKET_PATH, default)
        |
schema.query_agents ----> client_request.receive (control) -> Delivery.requestAgentSnapshot
        |                          |
        |                 Delivery.requestAgentSnapshot
        |                          |
schema.agent_snapshot <-- Delivery.prepare (same enrichment UI clients get)
        |
control.Snapshot.resolve  (pane id | unique title | --current via TELAR_PANE_ID)
        |
status == until ? exit 0 : sleep 250 ms, repeat until --timeout (exit 3)
```

```text
telar agent prompt 7 "run the tests"
        |
schema.send_pane_text{mode = prompt} -> client_request.receive -> pane_input.sendText
        |
pane_input.sendText: PaneStore.resolveControl(exact generation)
        |            agent_status.projectedStatus == blocked -> request_failed agent_blocked
        |            bracketed paste framing if the child enabled mode 2004, then Enter
        |
pane_input.forward  (history observer first, then the PTY queue)
        |
schema.request_completed
```

```text
telar pane read 7 --lines 40 --source recent
        |
schema.read_pane -> client_request.receive queues PendingPaneText
        |
encoder.encodeResponse resolves the pane at send time
        |
Pane.dumpText: last N rows of scrollback+screen (or of the screen), plain text
        |
schema.pane_text{truncated}
```

## Ownership

The runtime never keeps per-waiter state. A wait is a loop in the CLI process
over one-shot snapshot queries, bounded by the caller's timeout. The runtime
cost of a wait is one enriched snapshot every 250 ms on one control session.

`send_pane_text` resolves the pane by exact generation from the store rather
than from an attachment, because control clients attach nothing. The
attachment-independent half of pane input lives in the concrete
`forward` procedure in `src/backend/runtime/pane_input.zig` and
is shared with attached-client input, so history observation still precedes
the PTY queue for both.

A prompt to a blocked agent is refused in the runtime with `agent_blocked`.
The CLI cannot bypass it; only `pane send-keys` (raw mode) reaches a blocked
pane, which is how a script answers the prompt.

Text reads are late-bound: the response queue stores the pane key, rows and
source, and the encoder dumps the text into a fixed 64 KiB buffer when the send
slot frees. A pane that closed in between yields `request_failed
pane_not_found` instead of tearing the client down. The dump keeps the prefix
and sets `truncated` when older rows do not fit.

## Session reports

`telar agent report-session <pane|--current> <id>` sends
`report_agent_session`. The runtime validates the token shape, attaches it to
the agent aggregate of the exact pane generation and marks the session
checkpoint dirty; see [Session checkpoint](session-checkpoint.md) for how it
is used on restart.

## Pane identity

Every pane child receives `TELAR_SOCKET_PATH`, `TELAR_PANE_ID`,
`TELAR_WORKSPACE_ID` and `TELAR_TAB_ID`. `TELAR_SOCKET` remains absent by
design: a nested `telar server` must not inherit the outer listener as its own
endpoint. The CLI resolves `--socket`, then `TELAR_SOCKET`, then
`TELAR_SOCKET_PATH`, then the managed default.

## Validation

- `src/core/schema_contract_test.zig` pins `query_agents`, `read_pane`,
  `send_pane_text`, `pane_text` and `request_completed`.
- `src/backend/runtime/tests/requests_test.zig` proves prompt framing,
  raw passthrough, blocked refusal and stale-generation rejection through the
  concrete request operation and the real PTY queue.
- `src/backend/runtime/tests/read_pane_test.zig` proves row selection,
  truncation and late binding through the encoder.
- `src/backend/runtime/pane_launch.zig` proves the identity
  variables; `src/backend/proxy/proxy_namespace.zig` proves they survive proxy
  registration.
- `src/cli/parser.zig` and `src/cli/control.zig` prove the grammar, target
  resolution and JSON escaping.

## Pane references and authorship

Control pane references accept `pane_generation = 0` as "the pane's current
generation", so panes that never appeared in the agent snapshot stay
addressable (`PaneStore.resolveControl`). Text injected through
`send_pane_text` that submits a command (prompt mode, or raw text carrying
Enter) marks the pane's next completed history capture as agent-authored;
`telar history --author agent|human|all` and the history palette filter on
it.

## Worktree targets

Every `telar agent` target also accepts `worktree:BRANCH`. The CLI fetches
the worktree catalog and the agent snapshot and resolves the agent whose work
tree is that worktree (`Snapshot.resolveWorktree`); more than one is an
ambiguity error that lists their panes.

## Focus rule

`send_pane_text` and `interrupt_agent` fail with `pane_focused` when the pane
is the focused pane of the active tab of any attached UI client
(`agent_control.focusedByClient`, over the `ClientLayouts` each client
reports). A person is presumably typing there; the coordinator asks them
instead. `pane send-keys` is not exempt.

## Sender line and budget

A prompt sent from inside a telar pane carries that pane as `sender`. The CLI
sets it only when `TELAR_SOCKET_PATH` names the socket it talks to
(`control.senderPane`), so a CLI in another runtime's pane sends none. The
runtime ignores a sender pane it does not know, and prefixes a known one's
prompt with `[telar: from <branch or workspace>, pane N] ` so the worker
knows who asked. Prompts from one pane to another spend a `PromptBudget` of 8
per 60 s; the ninth fails with `prompt_rate_limited`. `agent wait` spends
nothing, so answers travel through waits rather than prompts back.

## Interrupt

```text
telar agent interrupt worktree:fix-tabs
        |
schema.interrupt_agent -> agent_control.interrupt
        |  focus rule; working agents only (agent_not_working)
        |  manifest InterruptKey (escape for Claude Code and Codex)
        |  pane_input.forwardControl
        |  ready report "Interrupted by telar"
        |
schema.request_completed
```

Claude Code runs no `Stop` hook for an interrupted turn, so the runtime
records the ready report itself; the agent's next hook overrides it.
`agent prompt --interrupt` interrupts, waits up to 15 s for the agent to
leave `working`, then sends the prompt.

## Progress reports and final answers

`telar hook` maps `PostToolUse` of `TaskCreate`/`TaskUpdate` (Claude Code),
`TodoWrite` and `update_plan` (Codex) to plan changes, and `Stop`'s
`last_assistant_message` to the final message (`hook_progress.map`). It
sends `report_agent_progress` before the lifecycle report, so a waiter that
sees `done` also sees the answer. `agent_hooks.receiveProgress` resolves the
hook's `cwd` to a worktree, registering an external one it did not know, and
`agent_status.observeProgress` stores plan and message on the agent.
`agent prompt --wait --json` and `agent get --json` return
`final_message`, `plan_done`, `plan_total`, `plan_step` and `work_tree`.

## Reading finished commands

A pane's last 16 KiB of text and its exit code survive its exit in the
`ExitedPanes` ring (16 panes). `read_pane` on an exited pane is served from
there with `exit_code` set, which is how `telar worktree exec --wait` prints
a finished command's output and exits with its code.
