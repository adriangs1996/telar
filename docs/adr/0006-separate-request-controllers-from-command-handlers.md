---
status: accepted
---

# Separate request controllers from command handlers

Runtime client messages currently enter through functions that may combine wire
translation, domain mutation, cross-capability effects and response delivery.
That makes a protocol boundary depend on every participant in the use case and
makes the domain transaction difficult to test without runtime infrastructure.
The tab rename flow is the first vertical slice to separate those concerns;
tab creation extends the design to a transaction spanning an aggregate, pane
launch, client attachment and response delivery; tab removal applies it to a
fact that can have either a client request or a runtime lifecycle trigger.

## Decision

The runtime event loop classifies each client message and delegates it to a
request-scoped controller. A controller owns protocol concerns: translating the
wire request into an application command, mapping expected command errors to
failure codes, and enqueueing the response for the requesting client. It does
not resolve aggregates, enforce domain invariants, update projections or
publish domain events.

An application command handler owns one use case. It resolves aggregates
through capability repositories, invokes aggregate behavior, defines the
transaction boundary and publishes the resulting typed domain events. Command
types contain the inputs needed by the use case, not wire request IDs or
response queues. A handler exposes a narrow erased executor so a controller can
be tested with a fake command implementation.

Aggregates remain the only authority for their invariants. A successful
mutation returns an owned domain event describing the committed fact. Domain
events contain stable domain identity and copied bounded values; they do not
contain client connections, response IDs, callbacks or borrowed request
buffers.

Domain events use narrow typed publisher ports and direct synchronous calls
within the runtime. The composition root binds request metadata, such as the
originating client, outside the domain event and connects concrete subscribers.
For `renameTab`, those subscribers advance the agent projection and mark other
observing clients for workspace resynchronization. This is not a universal
event bus and does not introduce allocation, serialization or asynchronous
delivery between modules in the same budget.

The successful order is aggregate commit, domain event publication, then client
response enqueue. Expected validation or lookup failures publish no event and
the controller returns one protocol failure. If response enqueue or later
delivery fails after commit, the runtime state and published effects remain
committed; reconnect and snapshot reconciliation recover the client. A
post-commit publisher used in this path is infallible. Fallible durable
persistence requires an explicit commit policy and does not hide behind this
publisher.

Some use cases have a wider commit boundary than one aggregate method. For
`createTab`, the handler proposes a tab identity and mutates the aggregate
provisionally, then launches the root pane through a narrow synchronous port.
Launch failure removes the provisional tab without consuming its identity or
advancing the workspace revision. Pane launch success commits the identity and
revision, publishes the owned `TabCreated` event, and only then attaches the
requesting client. Attachment and response-queue failures are post-commit and
therefore never remove the pane or tab. The workspace capability exposes no
shortcut that can commit a production tab without this runtime transaction.

For `closeTab`, the workspace repository operation is the commit point and
returns an owned `TabRemoved` event. The handler then invokes infallible ports
that start closing the tab's panes and publish that event before the controller
queues `TabClosed` for the requesting client. Response backpressure cannot
restore the removed tab or suppress its published effects. When the last pane
exits without a close request, lifecycle cleanup uses the same workspace
operation and the same `TabRemoved` fact; only the protocol adapter differs by
emitting `TabClosed` with no request ID.

Controllers live only for the request call. They may borrow decoded request
slices during that call. Anything retained by an aggregate, event, queue or
asynchronous boundary owns its bytes. The `renameTab`, `createTab` and
`closeTab` slices are the reference implementations for an aggregate mutation,
a wider launch transaction and a destructive transaction with two external
triggers. Other entrypoints migrate when their transaction and failure
contracts are understood and covered by tests.

This decision refines
[ADR 0002](0002-organize-capabilities-around-explicit-entrypoints.md). The
external entrypoint remains explicit, but a client mutation may divide its work
between a protocol controller and an application command handler instead of
assigning both responsibilities to one function.

## Considered options

- Keeping one entrypoint function for protocol, mutation and effects preserves
  fewer files but gives the boundary excessive authority and forces broad test
  fixtures.
- Letting controllers call repositories and aggregates directly couples domain
  behavior to the wire protocol and leaves transaction policy at the boundary.
- Publishing events from aggregates would make domain objects depend on
  infrastructure callbacks. Returning owned events preserves aggregate
  authority without giving it infrastructure knowledge.
- Naming the domain event `TabClosed` would encode the explicit request as its
  cause and misdescribe automatic removal after the final pane exits.
- Adding a process-wide event bus would add queueing, copying and failure modes
  where bounded typed calls are sufficient.
- Putting the originating client in a domain event would make a committed tab
  rename depend on the transport that requested it.

## Consequences

Each migrated mutation has an explicit protocol adapter, application handler,
aggregate operation and domain event. There are more small types, but each layer
can be tested against its own contract: controller tests use a fake executor,
handler tests use an in-memory repository and captured publisher, and aggregate
tests inspect invariants and event ownership.

Handlers that span capabilities use narrow synchronous ports rather than
receiving `Server`, client sessions or concrete infrastructure stores. This
keeps transaction ordering unit-testable while the composition root remains the
only code that converts those ports into pane launch, cwd authority, attachment
and workspace notification operations.

Response delivery no longer participates in domain commit. A client can miss a
confirmation for a mutation that exists, which is already required for a
long-lived runtime whose clients are disposable. Snapshot reconciliation is the
recovery mechanism.

The runtime composition root still wires concrete repositories, subscribers
and client queues. It is the only layer that needs to know those concrete
participants. Command handlers and controllers remain allocation-free and use
bounded fixed-size values for this flow.
