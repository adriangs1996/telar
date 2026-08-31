---
status: accepted
---

# Separate client delivery from attachment synchronization

Runtime-to-client delivery and client-to-pane synchronization obey different
invariants. Delivery chooses which bounded message one client receives next,
while an attachment tracks what that client has acknowledged for one pane.
Keeping both policies in the former monolithic runtime pump leaked attachment representation into
cross-message scheduling and mixes the interactive and media budgets.

## Decision

Each client session owns a `Delivery` module. It owns bounded message priority,
revision tracking and the logical send transaction. Management responses remain
queued, while snapshots, cells and graphics project the latest authoritative
runtime state instead of accumulating a visual replay. The runtime owns socket
I/O and actor scheduling; delivery owns the state transitions around that I/O.

`Delivery` moves through `ready`, `prepared`, `in_flight` and `closed` states.
It prepares bytes without consuming their source, commits immediately after the
runtime successfully schedules the write actor, and completes when that actor
returns. A scheduling failure closes delivery because the existing runtime
drops that client; retry would require a separate rollback decision. Delivery
owns the fairness cursor between attachments and receives only explicit,
read-only capability references. It never receives `Application`, the socket or the
scheduler.

Each client-pane relationship owns an `Attachment` module. It owns cell and
graphics acknowledgement, credit, snapshots, transfer staging and disposal.
Cell and graphics synchronization remain separate implementation modules behind
one attachment interface so media work cannot delay cell delivery.

`ClientSession` retains connection, receive and lifecycle ownership. Its
`Delivery` and `AttachmentStore` are siblings: delivery consults attachment
state but does not own attachment lifecycle. `AttachmentStore` hides storage and
lookup representation. Cell and graphics synchronization use closed internal
state machines so incompatible transfer, snapshot and acknowledgement states
cannot coexist.

Delivery never mutates attachment representation. Attachment never decides
priority between unrelated client messages. Tests exercise both supported
interfaces without adding polymorphic adapters solely for tests.

## Consequences

The migration first deepens `Attachment`, then extracts `Delivery`. It preserves
wire encodings, message priority, backpressure, allocation bounds and externally
observable behavior. Temporary forwarding aliases do not survive a completed
migration phase. Characterization tests precede both extractions. Later phases
extract explicit flow entrypoints and deepen the proxy root, with every phase
passing its functional, performance and native-platform gates independently.
