# Client event dispatch

Input, IPC, deadlines and worker completions enter a client-owned inbox. The
GUI, the headless client and the test drivers use `mailbox.GenericInbox`
(`lib/mailbox`). Their
consumers classify messages and delegate to existing operations. Only that
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
neither socket I/O nor operations execute while that mutex is held. The
optional wake callback must only signal a nonblocking host endpoint.

Messages own values or carry an explicit borrow from a producer resource:

| Source | Storage and end of borrow |
| --- | --- |
| Runtime RX | `RuntimeTransportState` owns both its 4 MiB `receive_buffer` and one validated `RuntimeMessage`. Inbox entries borrow the decoded value; handlers finish before the next read is armed. |
| Runtime TX | The `model.to_runtime` outbox plus the 4 MiB send buffer. One writer; completion releases the send claim. |
| Native input | `InputQueue` copies keys/paste before returning to AppKit/Wayland. One coalesced readiness message dispatches bounded chunks. |
| Headless stdin | One owned `InputLine` per `.input` event, parsed from a fixed `stdin_buffer`. The next line is read only after startup admits input and the outbox has room. |
| GUI presentation | A token and outcome. GPU consumers have finished before posting the completion. |
| Config, plugins and media | Existing generation/job owners retain results through dispatch or orphan cleanup. |
| Fixture RX | One explicit 64 KiB wire buffer and one decoded value owned by `presentation/Fixture`; a second pending receive or oversized frame is rejected. |

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
only for input readiness. Focus transitions use ordered `post` messages. Input
bytes and runtime deltas use owned storage and FIFO admission; they are never discarded by this
operation. FIFO plus finite admission bounds how much accepted work can precede
another source. Media decode/compression and observation work keep their own
workers; their completions carry results rather than heavy work to execute.

## Host consumers

Shared client work is queued in `Client.to_workers` and `to_background`. Each
adapter's `startJobs` pops those jobs and runs them as
`inbox.start(.client, .{ job_runner.run, ... })`; the GUI does so through
`gui/workers.zig`, and hands only the config watch to `ConfigurationReload`.
The finished `client.Message` arrives as the `.client` event and goes to
`Client.update`.

`gui/NativeLoop` uses the same inbox and a nonblocking wake pipe. Socket actors
use its task group. `ConfigurationReload` reserves a slot for its font/watch
worker, retaining its own join and staged-resource lifetime. Native callbacks
publish input readiness, focus and presentation completion. The window-thread
consumer is `GuiAdapter.update`, which classifies events and calls the shared
runtime/config operations directly. `NativeLoop` owns transport and wake resources,
not dispatch policy. `GuiAdapter.acceptInput` copies native input into the bounded
queue; `GuiAdapter.draw` seals a frame and `GuiAdapter.complete` consumes the
GPU result from the inbox.
`GuiAdapter.update` derives cursor state and decides whether to draw after
draining. `draw` prepares the latest projection. A reloaded configuration is
adopted at the start of `draw`, when no frame is in flight, because adoption
swaps the renderer and its font atlas; geometry changes run on that same
owner.

If a native frame's previous completion still awaits consumption, `render`
returns token zero. Both backends defer GPU submission until a later wake or
viewport change. Linux requests a surface frame callback only after admitting
a nonzero token, avoiding a callback wait with no surface commit.

`HeadlessClient.run` in `src/headless/` sleeps on `inbox.wait`, then calls
`HeadlessClient.update`. One turn dispatches the admitted events, synchronizes
client layout once, presents and acknowledges the ready frames, then arms the
next stdin read when input is admitted. See [Headless
client](headless-client.md).

`presentation/Fixture` and `src/client_tests/ClientHarness.zig` are test
drivers. They use the same inbox, decoder, production operations, outbox and
presentation lifecycle. Tests can delay messages and presentation
independently.

## Saturation, shutdown and recovery

A full outbox keeps its existing per-operation policies: retain native input,
delay the next headless stdin read, hold graphics credits, or reject a request
explicitly. Writers consume prepared bytes independently of the reader and the
model owner.
A failed worker admission releases the corresponding transport reservation.

Shutdown revokes inbox admission before canceling and joining producers. The
GUI joins its font worker before releasing staged renderers; both adapters
join socket workers before freeing their buffers, client generations and wake
endpoints. Late results cannot mutate a replacement owner. Socket failures or
uncertain partial writes end that client. Runtime panes survive and reconnect
rebuilds state through the existing snapshot protocol.

`InboxSnapshot` exposes depth, reserved slots, storage bytes, high-water count,
admitted/consumed messages, coalescing, rejections, stale publications, wakes
and budget yields through the inbox's `snapshot`. Window, transport and
diagram tests read it to check depth, reservations and consumption. Storage
bytes describe the inbox itself; the separate payload owners above remain
charged to their own budgets. Wakes count signal attempts, not kernel wakeups;
the native endpoint can coalesce several signals into one host callback.

## Validation

- `lib/mailbox/inbox_tests.zig`: full reservations, failed admission, stale and
  duplicate tickets, finite drains, time budgets, coalescing, concurrent
  publication, wake delivery and shutdown with a saturated queue.
- `connection/runtime_transport.zig`: a non-reading socket blocks TX while RX
  and local input continue, then cancellation joins both actors.
- `presentation/headless_tests.zig`: delayed owned wire bytes, ordered patches
  and dependent input, snapshot recovery, stale presentation tokens, retained
  frame lifetimes and allocation-free steady state.
- GUI tests: input/GPU completions wait for the consumer, pending input drains
  in bounded turns, config reload preserves in-flight resources and idle pumps
  consume no messages. Native window tests exercise deferred submission.
