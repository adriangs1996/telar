---
status: accepted
---

# Instantiate runtime through explicit dependencies

The runtime previously entered through `serve`, which selected concrete
infrastructure inside a private runtime type and made `Server` appear to be the
composition root. This hid the lifetime that owns the event loop and left no
public place to inject another implementation of a physical resource.

## Decision

`main.zig` is the process composition root. It selects production
implementations and initializes one public `Runtime` through a single
`Initialization` value. `Initialization` separates borrowed `Dependencies`
from runtime `Options`.

`Runtime` owns every live resource it opens through those dependencies. Its
public lifecycle is `init`, `run` and `deinit`: initialization acquires
resources with rollback, `run` classifies and delegates events, and `deinit`
performs ordered idempotent shutdown. The initialized value stays at one stable
address because internal coordinators borrow its fields.

The implementation separates that lifetime into three owned parts:

- `Resources` acquires physical capabilities and rolls them back in dependency
  order;
- `EventLoop` owns bounded event storage, selection and stop coordination;
- `Application` owns the live model, client-facing application state and
  cross-capability invariants.

`Runtime` composes those parts, starts the initial actors, delegates each event
and maps the global shutdown order. It does not implement requests, actor
completion policy or resource adapters itself. Request routing lives in
`application/request_dispatch.zig`; asynchronous integration lives in
`application/actor_bindings.zig`.

`serve` remains a small adapter for concurrent integration tests and callers
migrating to the explicit lifecycle. It cannot contain separate startup or
shutdown policy.

Dependencies gain a provider only when Telar has another implementation or a
required failure-injection seam. We do not add dynamic dispatch to every
capability in anticipation of a future adapter. Provider calls belong to
startup or the capability's existing budget; the interactive path keeps direct
typed calls.

This decision supersedes the sentence in
[ADR 0005](0005-keep-the-live-runtime-model-in-memory.md) that names `Server`
as the composition root. The former `Server` responsibilities are now divided
between the public runtime lifetime and its application, resource and event
adapters; there is no second server object.

## Consequences

The first dependency set contains the process `Io` implementation and backing
allocator. `Resources` constructs the current concrete listener, history,
proxy, PTY-environment and telemetry adapters. A capability gains an injected
provider only when Telar has another implementation or needs a production
failure boundary; the composition does not add dynamic dispatch pre-emptively.

The public runtime contract can now be tested without entering through
`serve`, and `main.zig` shows the complete lifetime directly. Client session
storage, request routing and actor coordination no longer live in
`instance.zig`, so changes to those policies do not enlarge the public runtime
lifecycle.
