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
schema.query_agents ----> request_router (control) -> QueryAgentsController
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
schema.send_pane_text{mode = prompt} -> SendPaneTextController
        |
SendPaneTextHandler: PaneStore.resolve(exact generation)
        |            Tracker.projectedStatus == blocked -> request_failed agent_blocked
        |            bracketed paste framing if the child enabled mode 2004, then Enter
        |
pane_input.Forwarder.forward  (history observer first, then the PTY queue)
        |
schema.request_completed
```

```text
telar pane read 7 --lines 40 --source recent
        |
schema.read_pane -> read_pane.Controller queues PendingPaneText
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
attachment-independent half of pane input lives in `pane_input.Forwarder` and
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

## Proof

- `src/core/schema_contract_test.zig` pins `query_agents`, `read_pane`,
  `send_pane_text`, `pane_text` and `request_completed`.
- `src/backend/runtime/tests/send_pane_text_test.zig` proves prompt framing,
  raw passthrough, blocked refusal and stale-generation rejection through the
  controller and the real PTY queue.
- `src/backend/runtime/tests/read_pane_test.zig` proves row selection,
  truncation and late binding through the encoder.
- `src/backend/runtime/application/pane_launcher.zig` proves the identity
  variables; `src/backend/proxy/root.zig` proves they survive proxy
  registration.
- `src/cli/parser.zig` and `src/cli/control.zig` prove the grammar, target
  resolution and JSON escaping.
