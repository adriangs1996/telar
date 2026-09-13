# Client event dispatch

Input, IPC, deadlines and worker completions enter a client-owned inbox. The
TUI, GUI and headless test driver use `client/execution/GenericInbox`. Their
consumers classify messages and delegate to existing handlers. Only that
consumer may mutate the client model or prepare a presentation.

## Admission and ownership

Each inbox has 64 slots, shared by ready messages and producer reservations.
`start(tag, .{ function, args })` reserves a completion slot before asking
`std.Io.Group` to run a producer. It returns `InboxFull` or `InboxClosed` before
starting work when admission fails. A successful reservation guarantees space
for that producer's result; publication cannot wait for a consumer to make room.
No extra scheduler or permanent thread per source is introduced.

The consumer alone starts and cancels workers. External producers publish into
reservations issued before they run; they do not race task creation against
inbox teardown.

`ProducerTicket` contains a slot and generation. Publication accepts it once.
An old or duplicate ticket cannot publish into a reused slot. Admission and
publication hold a mutex only around fixed inbox metadata and value copies;
neither socket I/O nor application handlers execute while that mutex is held. The
optional wake callback must only signal a nonblocking host endpoint.

Messages own values or carry an explicit borrow from a producer resource:

| Source | Storage and end of borrow |
| --- | --- |
| Runtime RX | `RuntimeTransportState` owns both its 4 MiB `receive_buffer` and one validated `RuntimeMessage`. Inbox entries borrow the decoded value; handlers finish before the next read is armed. |
| Runtime TX | Existing outbox plus the 4 MiB send buffer. One writer; completion releases the send claim. |
| TUI input | One reserved 4 KiB `host_input.chunk`. Decode and routing finish before rearming its reader. |
| Native input | `NativeInput` copies keys/paste before returning to AppKit/Wayland. One coalesced readiness message dispatches bounded chunks. |
| TUI host output | Sealed bytes owned by `Output`; no model pointer reaches its writer. |
| GUI presentation | A token and outcome. GPU consumers have finished before posting the completion. |
| Config, plugins and media | Existing generation/job owners retain results through dispatch or orphan cleanup. |
| Headless RX | One explicit 64 KiB wire buffer and one decoded value owned by the fixture; a second pending receive or oversized frame is rejected. |

The inbox does not make a borrowed slice independent of its owner. Rearming,
generation validation, release and orphan cleanup remain in their capabilities.
There is no queue of historical visual frames: ordered patches update one
owned model, while presentation captures the latest accumulated state.

## Consumer turns and wakeups

`begin` snapshots the ready-message count. `next` consumes FIFO order within
that boundary, stopping after 32 messages or 1 ms. A handler is indivisible:
it finishes before the budget is checked again. A turn always permits its
first message, even when its deadline has expired. `begin` rejects reentrant
dispatch. Results published during a turn remain for a later turn.

A transition from an empty inbox to a nonempty inbox sets a `std.Io.Event` and
signals the optional native wake endpoint once. Posting more messages preserves
them without writing more wake bytes. `end` signals again if a finite turn
left work. Queue inspection and resetting the empty event use the same mutex
as publication, so a wake arriving during a drain cannot be lost.

`notify` replaces a pending notification of the same tag. The GUI uses this
only for input readiness and the latest focus value. Input bytes and runtime
deltas use owned storage and FIFO admission; they are never discarded by this
operation. FIFO plus finite admission bounds how much accepted work can precede
another source. Media decode/compression and observation work keep their own
workers; their completions carry results rather than heavy work to execute.

## Host consumers

`frontend/client/run` sleeps on `inbox.wait`, then calls `events.drain`.
`events` classifies each message into its diagnostic path and delegates to the
existing adapter. Startup may advance after each message. A successful batch
observes layout and presentation once; unchanged versions schedule no frame.
Draw deadlines and host-write completions retain the presenter's existing
pacing and sealed-output contract. `events.handle` supplies the same dispatch
and observation for tests that deliberately execute one transition.

`gui/NativeLoop` uses the same inbox and a nonblocking wake pipe. Socket actors
use its task group. `ConfigurationReload` reserves a slot for its font/watch
worker, retaining its own join and staged-resource lifetime. Native callbacks
publish input readiness, focus and presentation completion. The window-thread
consumer delegates to `GuiClient` and the shared runtime/config handlers.
`Application` derives cursor state and prepares the latest projection after
draining. Font adoption and geometry changes run on that same owner.

If a native frame's previous completion still awaits consumption, `render`
returns token zero. Both backends defer GPU submission until a later wake or
viewport change. Linux requests a surface frame callback only after admitting
a nonzero token, avoiding a callback wait with no surface commit.

`presentation/Fixture` is the headless driver. It uses the same inbox, decoder,
domain handlers, outbox and presentation lifecycle. Tests can delay messages
and presentation independently. It remains a controllable test adapter rather
than a second CLI with unimplemented host services.

## Saturation, shutdown and recovery

A full outbox keeps its existing per-operation policies: pause TTY reads, retain
native input, hold graphics credits, or reject a request explicitly. Writers
consume prepared bytes independently of the reader and the model owner.
A failed worker admission releases the corresponding transport reservation.

Shutdown revokes inbox admission before canceling and joining producers. The
GUI joins its font worker before releasing staged renderers; both hosts join
socket/output workers before freeing their buffers, client generations and wake
endpoints. Late results cannot mutate a replacement owner. Socket failures or
uncertain partial writes end that client. Runtime panes survive and reconnect
rebuilds state through the existing snapshot protocol.

`InboxSnapshot` exposes depth, reserved slots, storage bytes, high-water count,
admitted/consumed messages, coalescing, rejections, stale publications, wakes
and budget yields. TUI diagnostics include these as `inbox_*` fields. Native
and headless drivers expose the same snapshot for integration probes. Storage
bytes describe the inbox itself; the separate payload owners above remain
charged to their own budgets. Wakes count signal attempts, not kernel wakeups;
the native endpoint can coalesce several signals into one host callback.

## Proof

- `execution/inbox_tests.zig`: full reservations, failed admission, stale and
  duplicate tickets, finite drains, time budgets, coalescing, concurrent
  publication, wake delivery and shutdown with a saturated queue.
- `connection/runtime_transport.zig`: a non-reading socket blocks TX while RX
  and local input continue, then cancellation joins both actors.
- `frontend/client/tests/host_interaction.zig`: finite TUI batches publish one
  presentation observation; terminal outcomes skip observation.
- `presentation/headless_tests.zig`: delayed owned wire bytes, ordered patches
  and dependent input, snapshot recovery, stale presentation tokens, retained
  frame lifetimes and allocation-free steady state.
- GUI tests: input/GPU completions wait for the consumer, pending input drains
  in bounded turns, config reload preserves in-flight resources and idle pumps
  consume no messages. Native window tests exercise deferred submission.
