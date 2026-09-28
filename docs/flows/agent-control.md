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
        |            bracketed paste framing if the child enabled mode 2004,
        |            then Enter for the child's keyboard mode (pane_input.enterBytes)
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
The CLI cannot bypass it; only `pane send-keys` (raw modes) reaches a blocked
pane, which is how a script answers the prompt.

## Enter

The runtime presses Enter; no caller writes a carriage return for it.
`send_pane_text` has three modes: `raw` sends the text unchanged, `raw_enter`
follows it with Enter (its text may be empty: Enter alone), and `prompt`
frames it as a paste when the child enabled mode 2004, then presses Enter.
Enter is encoded from the modes the pane's `vt.Terminal` holds: a child that
enabled any kitty keyboard flag gets `CSI 13 u`, any other child a carriage
return, which is also what shell history reads as a submitted command.

Agents read typed bursts as pastes, each by its own rule, so where Enter
lands decides whether text is submitted. Claude Code 2.1.283 and Codex
0.156.1 push kitty flags 5; measured in an isolated runtime:

| Sent in one write | Claude Code | Codex |
| --- | --- | --- |
| paste, then Enter (`prompt`) | submits | submits |
| under 100 raw bytes, then `\r` | submits | newline |
| 100 raw bytes or more, then `\r` | stays as text | newline |
| raw bytes, then `CSI 13 u` | submits | newline |
| raw bytes; Enter in a later write | submits | submits |

Codex does it on purpose: an Enter within 120 ms of a burst of three or more
characters typed under 8 ms apart inserts a newline
(`PASTE_ENTER_SUPPRESS_WINDOW` in `codex-rs/tui/src/bottom_pane/paste_burst.rs`).
So `pane send-keys "text" --enter` sends the text as `raw`, waits 150 ms and
sends `raw_enter` with no text, as a person presses Enter after typing, and
`agent prompt` keeps the paste and its Enter in one write.

Text reads are late-bound: the response queue stores the pane key, rows and
source, and the encoder dumps the text into a fixed 64 KiB buffer when the send
slot frees. A pane that closed in between yields `request_failed
pane_not_found` instead of tearing the client down. When the rows do not fit,
the dump keeps the newest whole lines and sets `truncated`.

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
- `src/backend/runtime/tests/agent_control_test.zig` proves, through the
  request dispatch and the pane's PTY queue, raw passthrough, Enter for a
  shell and for a kitty keyboard child, prompt framing, the focus rule, the
  prompt budget, the interrupt keys, the wait for the idle prompt and the
  cleared draft.
- `src/backend/runtime/pane_input.zig` proves submission framing per mode.
- `src/backend/runtime/tests/read_pane_test.zig` proves row selection,
  truncation that keeps the newest lines, and reads of exited panes through
  the encoder.
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
reports). The rule checks focus, not typing: a person may type into a
focused pane at any moment, so the coordinator asks them instead. `pane
send-keys` is not exempt, and the message says what was checked.

`telar tab create --client ID` asks that UI to open the tab, and the UI
moves its focus to it, as when the person opens one; the new pane then
refuses text. `telar tab create --background` sends `launch_tab` instead:
the runtime opens the tab and its shell in the workspace's directory
(`tab_creation.launch`), leases no geometry and attaches nobody, so every
UI keeps its focus and a script may type into the new pane at once. It is
the path `worktree exec` already took (`tab_creation.open` serves both).

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
        |  focus rule; an interrupt pressed under 2 s ago completes without
        |    a key, an older pending one presses again
        |  working agents only (agent_not_working)
        |  manifest InterruptKey -> pane_input.press (encoded by keyinput)
        |  settling report "Interrupted by telar"; agent.interrupt = pending
        |
schema.request_completed
        .
        .  later, on the observation path
        .
pane_observation.finish
        |  agent_control.clearRestoredDraft: Claude Code idle with its old
        |    prompt back in an unfocused composer -> one more key press
        |  agent_status.observeScreen: a ready_confirmed screen newer than
        |    the key starts interrupt_idle_at; any other screen clears it
        .
agent_maintenance.tick (1 s) -> Agent.expire -> settleInterrupt
        |  screen_shows_idle (Claude Code, Codex, Cursor Agent): idle
        |    composer held interrupt_idle_ms (500 ms)
        |  other agents: interrupt_blind_ms (3 s) after the last press
        |  -> the settling report goes and weaker evidence decides
```

| Agent | Key | Source |
| --- | --- | --- |
| Claude Code | Ctrl+C | measured, and docs: "Interrupts a running operation. If nothing is running, the first press clears the prompt input and a second press exits"; Escape only enters NORMAL mode in vim mode |
| Codex | Escape | measured: the turn stops and the composer empties |
| OpenCode | Escape twice | source of 1.18.30: `session_interrupt` aborts on the second press within 5 s; not measured |
| Pi | Escape | source of 0.85.1: `app.interrupt` in `keybindings.js`; not measured |
| Cursor Agent | Escape | source of 2026.09.26: aborts the run when the input is empty; not measured |

Claude Code reports nothing when its turn is interrupted: with hooks on
every event, 2.1.283 runs none after Ctrl+C. OpenCode and Pi report their
next state through their integrations (`session.status` going idle,
`agent_settled`), and that report replaces the runtime's. So the runtime no
longer pretends the turn ended when it pressed the key. The settling report
keeps the agent `working` until screens drawn after the key show the idle
composer for 500 ms, the agent's next report replaces it, or it expires.
OpenCode and Pi have no screen scan that shows them idle; without their
integration, their interrupt settles 3 s after the key. A repeated
interrupt presses the key again once 2 s have passed since the last press,
so a key that did not take is not swallowed, while two presses never land
inside the 0.8 s in which Claude Code exits on a second Ctrl+C. The wait is not a guess about how long an agent takes to stop: it
starts only once the composer reads as idle, and it absorbs a measured
race. Claude Code writes its idle title (`✳`) and, 1 ms later in a separate
synchronized frame, the composer with the prompt it put back; an
observation between the two sees an idle, empty composer that is about to
change. `agent prompt --interrupt` interrupts, waits up to 15 s for the
agent to leave `working`, then sends the prompt; `InterruptNotSettled`
otherwise.

Claude Code's idle prompt is only readable with two facts from 2.1.283: it
writes a no-break space after `❯`, which the scan used to treat as text, so
it never saw the prompt as idle; and it keeps the composer on screen during
a turn, so the scan also needs its title: `◐` and `◑` while a turn runs, `✳`
otherwise.

Claude Code interrupted before it answered puts the prompt back in its
composer, so the next prompt would be appended to it. Its title shows `✳`
once the turn stopped; with that title and a prompt row that holds text,
`prompt_scan.showsRestoredDraft` holds, and the runtime presses Ctrl+C once
more, which clears input when nothing runs. It is a key decided by a screen
reading, the one exception to "a heuristic never authorizes input", and it
is bounded: once per interrupt, never at an empty prompt, where a second
Ctrl+C would exit, and never in a pane a person has focused since the
interrupt, whose text may be theirs. That press shows "Press Ctrl-C again to exit" for about
0.8 s (measured); a Ctrl+C from anyone within that window exits Claude Code.

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
`ExitedPanes` ring (16 panes). The dump keeps the newest whole lines, so a
verbose command keeps its test summary or final error. The record notes
whether older rows were dropped, either past the 200 rows it keeps or past
its 16 KiB. `read_pane` on an exited pane is served from
there with `exit_code` set and `truncated` true when the requested rows reach
the dropped ones, which is how `telar worktree exec --wait` prints a finished
command's output and exits with its code.
