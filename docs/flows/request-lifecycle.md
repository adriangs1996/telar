# Client request lifecycle

This flow starts when a client adapter sends a request that expects one
terminal runtime response. It ends when that response consumes its typed
continuation, canonical lifecycle makes it stale, or the client dies.

## Boundary

`request_lifecycle.State` owns two disposable client values:

- the next nonzero request identity;
- one fixed `requests.Tracker` of typed continuations.

The tracker has `schema.max_panes_per_tab + 8` slots and allocates nothing.
Generated identities start at 2 because bootstrap owns identity 1. Zero marks
an autonomous runtime lifecycle message, and `maxInt(u64)` is a terminal
sentinel rather than a reusable identity.

This state does not decide whether a tab move, pane split or snapshot is valid.
Each client adapter constructs its protocol message and validates the matching
response. Application handlers receive typed values without request IDs.

## Starting a request

```text
client use-case effect
        |
request_lifecycle.nextId
        |
check one tracker slot and request-ID space
        |
adapter constructs message and Continuation
        |
request_lifecycle.deliver
        |
Tracker.add -> runtime_transport.enqueue
        |
local rejection -> Tracker.take rollback
```

The client loop is single threaded, so identity allocation and delivery cannot
interleave with another request start. `deliver` registers the continuation
before it gives the message to transport. If bounded copying or outbox capacity
rejects the message, `deliver` removes that continuation. It does not reuse the
identity.

Renames, launches and notifications use delivery functions that call the
outbox's owned-copy entrypoints. Fixed-size requests use `deliver` directly.
The request lifecycle never borrows text beyond the synchronous call.

Tab close is the one preflight that needs two consecutive identities. Its
failure path may request a canonical tab snapshot after close delivery fails.
`ensureCanStart(client, 2)` proves both identities and one tracker slot exist
before provisional attachment effects begin.

Bootstrap registers `initial_open` before `runtime_transport.State.bootstrap`
sends its synchronous frames. No read starts until that registration and all
three bootstrap writes finish.

## Consuming a response

```text
runtime_transport.handleRead
        |
decoded terminal response
        |
slice adapter -> request_lifecycle.consume(request_id)
        |
typed Continuation
        |
verify request kind and exact target
        |
application handler
```

`consume` removes a known continuation before the adapter validates its type or
target. An incompatible, malformed or replayed terminal response therefore
cannot reuse the same request. An unknown identity is a protocol error.

Runtime `request_failed` follows the same rule. The adapter consumes the
continuation once, then the failure use case chooses recovery, notification or
fatal client shutdown.

## Canonical retirement

A workspace or tab snapshot may make an in-flight request obsolete before its
response arrives. `ignoreTab` and `ignorePane` retain the identity but replace
the continuation with `ignored`. A late response can then be recognized and
dropped exactly once.

Split requests are different. Their success can introduce a new pane that the
client must detach even when the original target vanished, so canonical
retirement keeps their typed continuation. Tab detachment retires only matching
attachment continuations. Pane exit directly completes the matching
`close_pane` continuation because the exit is its authoritative success signal.

## Failure and lifetime

The request lifecycle runs on the interactive path with fixed storage and
bounded scans. Tracker operations are `O(schema.max_panes_per_tab)`. A full
tracker or exhausted identity space rejects work before allocation.

An asynchronous socket failure after accepted delivery terminates the client;
the lifecycle does not invent a runtime response or retry an uncertain write.
Client destruction drops every continuation. Runtime-owned panes, tabs and
workspaces remain valid, and a new client rebuilds its projection from
snapshots.

## Proof

- `src/frontend/client/request_lifecycle.zig` proves identity bounds, recovery
  preflight and refusal before tracker overflow.
- `src/frontend/client/requests.zig` proves single consumption, group and pane
  lookup, exact close completion and stale-retirement exceptions.
- `request delivery rolls correlation back when transport is full` in
  `src/frontend/client/client_test.zig` crosses the public request and transport
  boundaries and proves transactional rollback.
- Bootstrap and the request-specific client tests prove exact wire identity,
  owned payload delivery, incompatible continuation rejection and late-response
  handling.
