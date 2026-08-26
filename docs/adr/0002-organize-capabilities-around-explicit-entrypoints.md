---
status: accepted
---

# Organize capabilities around explicit entrypoints

Telar must make both state ownership and user-visible flows discoverable. We
organize state and invariants into capability namespaces, while every external
event enters a process through one explicit entrypoint. This preserves the
runtime/client ownership boundary without hiding behavior inside technical
subsystems.

## Decision

A capability directory owns one cohesive abstraction or one indivisible set of
invariants. Its `root.zig` is the supported public namespace; files inside the
directory are implementation details. A file owns one primary abstraction and
exposes the smallest complete protocol for it. There is no numeric limit on
public methods.

Client and runtime event loops classify events and delegate immediately to
entrypoints. An entrypoint owns orchestration, ordering, transaction policy and
rollback for one external event. It uses capability APIs and does not mutate
their representations directly. Protocol messages connect entrypoints across
the process boundary.

User-visible flows are named separately from capabilities because one flow may
cross several owners, asynchronous events and both processes. Each flow records
its frontend entrypoint, protocol messages, runtime entrypoints, resulting
events and integration proof.

Unit tests live with the abstraction whose invariants they inspect. Contract
and integration tests live outside capability internals and use the language of
the flow they prove.

## Considered options

- Organizing only by technical subsystem makes ownership visible but hides the
  path followed by an external event.
- Organizing whole user features in one directory crosses runtime/client
  ownership and encourages shared live state.
- Limiting every file to one public method rewards wrappers even when a
  stateful abstraction needs a small lifecycle protocol.
- Keeping orchestration inline in the main event loops makes every flow depend
  on prior knowledge of those loops.

## Consequences

Directory structure alone is not the behavior map. Capability namespaces show
ownership; entrypoints and flow tests show causality. Some flows have several
entrypoints because the socket, PTY and worker queues create real asynchronous
boundaries.

The initial migration changes structure only. Existing wire encodings,
ownership, event ordering, budgets, bounds and externally observable behavior
remain unchanged.
