# Architecture audit implementation

Base: `16b8205`. Each numbered item is implemented and committed independently.
The existing runtime/client split and interactive, media and observation budgets
remain constraints, not targets for consolidation.

## 1. History producer ownership

- A session-owned atomic `Sequence` reserves unique SQLite-compatible identities
  for concurrent producers; exhaustion never wraps. No producer mutates a raw
  counter. Reservation does not require waiting for the observation worker.
- Runtime reports go through `Pane.recordAgentCommand`, which captures runtime
  geometry instead of borrowing the observation actor's private terminal.
- Removed history-service plumbing from hook and plugin adapters.
- Proof: concurrent reservation and exhaustion tests; an agent-report test leaves
  the observation terminal uninitialized to verify that it is never accessed.
- Validation: `zig build test --summary all` passed.

## 2. Checkpoint ownership

- Pending checkpoint state owns its buffer and allocator as one optional value.
- Scheduling transfers ownership before starting the worker; both startup failure
  and completion release it through the same idempotent transition.
- Removed the application's separate buffer field and the duplicate free path.
- Proof: injected scheduler failure, retry, duplicate completion, debounce and
  disk-failure tests. `zig build test --summary all` passed.

## Remaining items

3. Request dispatcher and pane-focus transaction.
4. Frontend transport/event coordination boundary.
5. History inspection geometry independent of widgets.
6. Git observation reservation protocol.
7. Provider session-file adapters.
8. Agent observation values independent of producers.
9. Client submodels and revisions.
10. Pane media ownership and dependency cycle.
11. Kitty codec, sidebar rendering and transmission transitions.
12. Attachment capture, markers and presentation.
13. Configuration generation, parsing and module loading.
14. History search policies and bounded result accumulation.
15. Modal-specific prompt state and semantic selection.
16. Atomic history page request/result transitions.
17. Shared incremental HTTP/2 framing.
18. Per-command CLI grammars and argument cursor.
