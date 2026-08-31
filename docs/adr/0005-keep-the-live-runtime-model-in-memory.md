---
status: accepted
---

# Keep the live runtime model in memory

[ADR 0007](0007-instantiate-runtime-through-explicit-dependencies.md)
supersedes only this ADR's assignment of the composition-root role to
`Server`. The model and infrastructure ownership decision remains unchanged.

Telar needs an authoritative model that components can query without coupling
domain behavior to sockets, workers, databases or other runtime machinery. The
live model remains in memory for the lifetime of the runtime. A persistence
adapter selected at startup hydrates restorable state and records explicit
changes outside the interactive path.

## Decision

`Runtime` composes two different kinds of ownership. Its `Application` owns the
runtime model and application state such as workspaces, tabs, pane identity and
lifecycle, agent state, validated configuration and typed session references.
Its `Resources` and `EventLoop` own runtime-wide allocators, queues, listener,
proxy, storage connection, telemetry and scheduling machinery. `PaneStore`
still co-locates each pane's semantic state with its child, PTY and terminal
resources because their lifecycle is indivisible today; this is the explicit
transitional exception described below.

`RuntimeModel` is passive data ownership, not a service or aggregate. It exposes
no domain commands and performs no infrastructure work. Capability APIs resolve
aggregates through repositories backed by the model, apply behavior on those
aggregates and construct explicit projections from the committed state.

The distinction is contractual rather than a demand for two disconnected
object graphs. A capability may keep semantic state next to a live resource
when their invariants or memory locality require it. Its public root must still
expose domain operations, bounded queries and explicit projections instead of
leaking handles or storage representation.

The workspace capability is the first complete implementation of this
boundary. `PaneStore` and the agent `Tracker` remain transitional capability
roots inside `RuntimeModel` until their semantic state can be separated from
live resources and observation behavior. They are not checkpoint types and
must not be serialized as if that separation already existed.

The runtime model is not public client data. Components reach it through
capability APIs, aggregates, trackers and in-memory repositories. Clients
receive allowlisted protocol projections. Sensitive configuration, credentials
and session references never become client-visible merely because the model
owns them.

Repositories hold the live aggregates in memory. They are synchronous, bounded
and subject to the budget of the path that calls them. A repository is not a
persistence adapter and cannot be transparently replaced by SQLite, filesystem
I/O or another backend with different latency and failure semantics.

Persistence is a separate port selected when the runtime starts. A volatile
adapter supports tests and non-durable sessions; a future durable adapter may
use SQLite or another local store. The adapter loads a checkpoint before the
runtime begins accepting mutations and receives owned persistence records or
checkpoints after semantic changes. Ordinary runtime queries continue reading
the in-memory model.

Aggregates do not save themselves. An application command handler validates and
applies a command through capability, aggregate and repository APIs, then
submits any resulting persistable change to the persistence capability. A
request controller remains responsible for translating the client protocol and
delivering its result. Each operation must state whether client confirmation
requires durable commit or whether bounded write-behind is acceptable. A
durable commit runs in a worker and never blocks the event loop. Failure policy,
retry bounds and unsaved-state reporting belong to that operation's contract.

Calls within one process and one latency budget remain direct typed calls. We
do not introduce a universal event bus or serialize messages merely to cross a
module boundary. Owned messages, IDs and generations are required when work
crosses a thread, process, asynchronous lifetime or one of Telar's interactive,
media and observation budgets.

The live aggregate, durable record and client projection are separate types.
Mappings between them are explicit and tested. This permits persistence and
wire schemas to evolve independently, prevents accidental disclosure and keeps
non-restorable values out of checkpoints. File descriptors, PTYs, allocators,
pointers, callbacks, queues and in-flight work are never persisted.

Client reconnection rebuilds disposable client state from bounded projections
of the still-running model. Runtime restart loads only the values represented
by a durable checkpoint and reconstructs fresh infrastructure around them. It
does not claim continuity for child processes or PTYs; that requires a separate
supervisor which owns their master descriptors.

## Considered options

- An Active Record design would let aggregates call `save` and make storage
  concerns part of domain behavior. It would also invite database access from
  paths whose latency contract permits only bounded memory operations.
- Making one repository adapter interchangeable between fixed memory and a
  database would hide incompatible latency, allocation, blocking and failure
  behavior behind the same synchronous API.
- Persisting every internal mutation would turn PTY bytes, terminal cells and
  cursor changes into storage traffic. Only semantic changes selected by a
  capability produce persistence records.
- Routing all component interaction through a bus would add queueing, copying
  and scheduling where a direct call already preserves ownership.
- Serializing `Runtime`, `Application` or live aggregate memory would retain
  process-local resources, expose private data and bind recovery to unstable
  memory layout.
- Keeping all state volatile would preserve current latency but prevent tested
  runtime recovery and make later durability depend on representation leaks.

## Consequences

The runtime's immediate source of truth remains memory. Persistence can fail or
lag without delaying PTY, VT, input or rendering work, but an operation cannot
claim durability until its selected commit policy completes.

The model, wire protocol and persistence schema intentionally contain some
similar data in different types. That duplication is the boundary which keeps
security, versioning and recovery policies independent.

Persistence implementations require contract tests for restart, corrupt data,
wrong ownership, stale generations, disk full, queue saturation and worker
failure. Performance tests must prove that model extraction and persistence add
no steady-state allocation or blocking work to the interactive path and must
report tail latency rather than assuming an adapter is free.
