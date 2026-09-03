# Engineering invariants

These rules turn Telar's architecture into reviewable contracts. An
unqualified rule is mandatory. Record and justify any exception beside the
code that needs it.

## Change checklist

Before adding a feature, name its:

- owner: runtime, client, shared value, or external worker;
- budget: interactive, media, or observation;
- authority: who may read, mutate, and trigger it;
- bounds: bytes, items, time, processes, and queue depth;
- lifecycle: create, replace, cancel, detach, reconnect, and destroy;
- recovery: snapshot, replay, fallback, or explicit failure;
- proof: tests, metrics, and failure injection.

A design is incomplete while any item is unknown.

## Code organization and tracing

- A capability directory owns one cohesive abstraction or one indivisible set
  of invariants. Its `root.zig` is the supported public namespace.
- Files inside a capability directory are implementation details. Code outside
  the capability imports its `root.zig`, not those files directly.
- A file owns one primary abstraction and exposes the smallest complete
  protocol for it. Method count and line count are not design targets.
- An external event has one explicit entrypoint in the process that receives
  it. Event loops classify and delegate; they do not contain the flow itself.
- A new or materially refactored client mutation uses a request controller for
  protocol translation, expected-error mapping and response delivery. The
  controller does not mutate domain state or publish domain events.
- Its application command handler owns domain orchestration, ordering,
  transaction policy, rollback and event publication. It calls capability APIs
  and does not mutate their representations directly.
- A domain event produced by a committed aggregate change is owned and typed.
  Client identity, request IDs, callbacks and borrowed request buffers are not
  domain event data.
- Protocol messages connect entrypoints across processes. Message names remain
  stable search terms on both sides of the connection.
- A user-visible flow records its external trigger, process entrypoints,
  protocol messages, resulting events and integration proof.
- Unit tests live with the abstraction whose invariants they inspect. Contract
  and integration tests use public APIs and the language of the flow they
  prove.
- An extraction is complete only when callers know fewer implementation
  details. A forwarding wrapper that preserves the same knowledge is not a new
  abstraction.

## Ownership and failure

- The runtime owns PTYs, child processes, terminal state, agent truth, graphics
  emitted by children, and durable history.
- The client owns layout, focus, hover, selection, scroll position, host
  capabilities, physical graphics placements, and other disposable UI state.
  The runtime may retain a bounded, validated layout replica for reconnect; it
  never becomes the authority that mutates client layout.
- `telar-core` shares types and pure operations. It owns no live runtime or
  client state.
- The VT emulator alone defines child screen semantics. Observers may tap bytes
  but cannot define or mutate the screen.
- Rendering changes buffers or graphics state. It never writes around the
  renderer through an unrelated output path.
- Client death leaves runtime state valid. Reconnection rebuilds cells and
  graphics from snapshots.
- Runtime death currently loses live PTYs. Do not promise crash-safe process
  continuity without a supervisor that owns their master descriptors.
- Async work retains IDs and generations, not borrowed pointers. Completion
  resolves the owner again and discards stale results.
- Plugins, observation workers, and clients cannot crash or block the runtime
  loop.

## Three paths

### Interactive

- Carries input, PTY bytes, VT state, cell damage, and terminal responses.
- Drains the PTY before rendering or observation work.
- Built-in input routing performs no filesystem, database, JSON, Lua,
  process-tree, network, or plugin work.
- After the native router matches an explicit user binding, it may call a
  client-owned Lua callback. The callback has hard memory, instruction,
  wall-time, result-count, and result-byte limits. Its latency affects only
  that client. Runtime input, PTYs, and other clients continue independently.
- A Lua binding receives an immutable value snapshot and returns validated
  semantic effects or semantic input. It cannot retain Zig pointers, mutate
  client state reentrantly, emit terminal bytes, or call runtime internals.
- Runtime Lua and downloaded plugin Lua never execute synchronously in this
  path. Native bindings never enter Lua.
- Allocates nothing in steady state. Fixed buffers and bounded rings cover
  expected bursts. Invoking an explicit Lua binding may allocate only inside
  its quota-accounted client VM; the router and runtime side remain
  allocation-free.
- Coalesces obsolete frames. It does not queue a visual replay.

### Media

- Carries KGP payloads, decoded images, compression, and client image transfer.
- Has independent queues, workers, quotas, pacing, and metrics.
- Large decode, compression, hashing, or copy work cannot delay input or cell
  output.
- Repeated frames use latest-wins semantics where protocol ordering permits it.
- Media failure leaves the text terminal usable.

### Observation

- Carries agent inspection, history, proxy records, search, Git state, and
  analytics.
- Runs behind bounded queues and may allocate or block in its workers.
- Saturation drops or degrades observation according to an explicit policy. It
  never blocks PTY traffic.
- Loss, queue depth, and latency are observable.

## PTY, VT, and rendering

- Process each PTY burst as drain, parse, update canonical state, accumulate
  damage, fold, then publish.
- Hidden panes keep parsing output but produce no client render work.
- Idle panes and clients schedule no polling or repaint proportional to their
  count.
- Parsers preserve state across arbitrary read boundaries. Test every control
  sequence split at every byte.
- Terminal queries have explicit ownership and expiry. A late response is
  consumed as stale protocol traffic, never leaked into a pane as input.
- Parse host input into semantic events, route it, then encode it for the
  child's active terminal modes. Raw host input is not copied to the child.
- Bracketed paste identifies paste. Timing heuristics do not.
- A mouse `down` chooses one owner for its whole gesture. The same owner receives
  every matching drag and `up` event.
- Focus changes before a newly focused pane receives the triggering event.
- Synchronized output spans reads and commits one complete frame or expires by
  an explicit recovery rule.

## IPC and multiple clients

- Runtime state is canonical. Every client has independent acknowledged cell
  and graphics state.
- A slow client cannot delay PTYs, other clients, or persistence workers.
- When a client falls behind, discard intermediate patches, mark it for
  resynchronization, and send a bounded snapshot.
- Every wire frame has a checked byte limit before allocation or decoding.
- The handshake accepts one exact schema fingerprint. Change the fingerprint
  whenever an existing encoding changes and reject every mismatch; do not add
  historical decoders before rolling upgrades become a product requirement.
- Runtime feature capabilities are explicit messages. Unknown required fields,
  tags, and capabilities fail explicitly.
- Messages use stable IDs and generations. Reuse never makes an old message
  valid for a new object.
- One client holds the geometry lease for a PTY. The policy for acquiring,
  transferring, and losing that lease is explicit.
- The geometry owner sets `cols`, `rows`, `xpixel`, and `ypixel`. Spectators
  crop, scale, or letterbox without resizing the child.
- Host terminal capabilities belong to each client. Never promote one client's
  KGP, mouse, clipboard, or color support into global runtime truth.
- Remote transport preserves the same framing, bounds, negotiation, and
  backpressure as local transport.

## Graphics

- Telar terminates KGP from children. Raw child graphics sequences never pass
  directly to the host terminal.
- The runtime owns child image bytes, child IDs, generations, placements,
  placeholders, quotas, and protocol responses.
- The client owns host image IDs, host placements, clipping, scaling, z-order,
  capability probing, and cleanup.
- Image identity is `(pane_id, child_image_id, generation)`. Sampled hashes are
  not identity.
- An image remains alive while any placement, placeholder, scrollback entry, or
  in-flight transfer references it.
- Resize, font-size change, layout change, attach, and reconnect rebuild physical
  placements from canonical state.
- Child graphics are clipped to their pane and cannot cover Telar chrome,
  modals, or another pane.
- Validate dimensions, multiplication, decoded length, chunks, compression,
  counts, and per-pane and global bytes before committing storage.
- File media accepts only validated regular files owned by the expected user.
  Shared memory validates its name, declared length, mapping and ownership where
  the platform exposes it. Both include unlink and crash cleanup.
- The sidebar uses KGP for visual enrichment and cells for terminal semantics.
  Text, focus, editing, and every action retain a cell fallback.
- Removing KGP may reduce visual fidelity. It cannot remove a Telar function.

## Agent state

- Every observation records source, confidence, pane generation, process
  identity, session identity, sequence, timestamp, and expiry.
- Prefer full official lifecycle reports, then partial official reports,
  foreground process state, OSC markers, screen heuristics, and unknown state.
- A heuristic may change presentation. It cannot authorize input, approval,
  termination, restore, or another destructive action.
- Agent authority is a state machine with candidate, active, obscured, resumed,
  exited, and stale transitions. One contradictory sample cannot revoke a live
  session permanently.
- Process detection starts from `tcgetpgrp` or an equivalent constant-cost
  signal. Scan or inspect processes only after a relevant change and cache the
  result.
- Detection and Git status run in observation workers, never in an API request,
  render, or input handler.
- Persist typed session references, not resume commands. Restore validates an
  official agent allowlist and reconstructs a fixed argv.
- Reject malformed, option-looking, duplicated, stale, or wrong-owner session
  references before launch.
- Distinguish reattach, restore, resume, and handoff in code, UI, and docs.
- The runtime decides audible agent transitions and publishes pane identity
  plus generation. Only clients touch host audio, and playback stays on the
  observation path.

## History and proxy

- Capture is best effort and isolated from traffic forwarding.
- Bound scrollback, structured history, query results, and pending records by
  bytes as well as counts.
- Remove secrets before constructing storable text. Redacting only at display
  time is too late.
- Response bodies are opt-in until a proven redaction and retention policy
  exists.
- State directories are owner-only. Durable writes are atomic and preserve a
  corrupt prior file for diagnosis.
- TLS interception is opt-in, scoped, and permanently visible while active.
- Installing a CA into a system trust store is a separate user-authorized
  action.
- Observation failure never changes the forwarded HTTP, HTTP/2, TLS, or PTY
  stream.
- Exchange listeners receive only whole completed exchanges. Their bounded
  queues drop obsolete work, and proxy relay never waits for a listener.

## Lua configuration

- Treat configuration Lua as trusted user code whose failures still require
  containment.
- Runtime configuration is evaluated in a disposable loader and converted to
  validated, typed Telar values. No live Lua value enters the runtime.
- Client configuration without callbacks is also disposable. When it declares
  Lua callbacks, the client owns one live VM generation containing those
  closures. The VM is client state and never enters the runtime, renderer, or
  another client.
- Callback APIs append bounded semantic effects to a batch. Zig validates the
  complete batch after Lua returns and before applying any effect. Lua never
  receives mutable Telar objects or borrowed pointers.
- A config reload builds and validates a complete replacement before one atomic
  swap. Client reload replaces the typed snapshot, callback registry, and Lua
  VM as one generation. Failure keeps the previous generation active; stale
  completions are discarded by generation.
- The default config environment exposes pure constructors and data. Filesystem,
  process, network, debug, native module, and control-socket access require an
  explicit user decision.
- Config declares semantic actions and stable IDs. It does not patch internal
  structs or emit terminal bytes.
- Normal Lua bindings return semantic effects. Expression bindings return
  semantic keys, paste, consume, or forward decisions; the client encodes them
  for the focused child's terminal modes. Error and timeout consume the
  matched binding unless its configuration declares another safe fallback.
- Closure state is ephemeral and is lost on reload. Durable state uses a
  host-managed typed API and is never restored as Lua bytecode or closures.
- Config has an API version. Reject incompatible versions with a concrete
  migration error.

## Lua plugins

- A plugin executes outside the runtime process, with one disposable Lua VM or
  worker per plugin.
- Declarative metadata identifies the plugin, API version, entrypoints, source
  revision, and requested capabilities before its Lua code executes.
- Discovery, acquisition, inspection, trust, enablement, and execution are
  separate states. Network content never becomes executable through discovery
  alone.
- Pin installed source to an immutable revision. Show build and startup commands
  before authorization.
- Bind execution authority to a whole-package digest. Execute a private,
  revalidated invocation snapshot so mutable package files cannot change
  between inspection and worker startup.
- A plugin receives scoped API capabilities through a broker, not the runtime's
  global control socket or credentials.
- Enforce memory, instruction, wall-time, output, child-process, concurrency,
  event-queue, and restart limits outside the plugin VM.
- Cancellation terminates the plugin's work and descendants. Runtime shutdown
  does not wait forever for plugin cleanup.
- Plugin callbacks publish commands or data. They never run synchronously inside
  PTY, render, input, or state-mutation callbacks.
- Events carry stable IDs and generations. Plugins tolerate replay and missed
  events by querying a current snapshot.
- Durable plugin state uses a host-managed directory or API. VM memory is never
  persistence.
- A same-user plugin with filesystem, process, native module, or network access
  is full-trust code, not a sandboxed extension. State that plainly in the UI.

## Local authority and storage

- Socket directories use owner-only permissions and reject wrong-owner,
  symlinked, hard-linked, stale-but-live, or non-regular endpoints.
- Peer UID checks protect against other accounts. They do not isolate processes
  running as the same user.
- Child panes inherit no global runtime socket, token, plugin authority, or
  observation credential by default.
- Pane integrations receive the smallest capability that can report their own
  state.
- Persisted state cannot restore arbitrary argv, hooks, Lua closures, plugin
  enablement, or executable authority without revalidation.
- Remote attach negotiates binary and protocol compatibility before mutation.
  Remote executable installation or replacement requires explicit approval.
- Terminal capabilities and local file or shared-memory transports never cross
  a machine boundary by assumption.

## Release gates

Every affected rule above needs a test or an explicit proof argument. At minimum,
the suite covers:

- client death during every async operation;
- pane death with output, queries, history, and graphics in flight;
- slow and non-reading clients followed by snapshot recovery;
- simultaneous clients with different geometry and capabilities;
- full-screen output floods in visible and hidden panes;
- zero-work idle behavior as pane count grows;
- parser boundary, malformed input, fuzz, and allocation-failure cases;
- KGP replacement, deletion, placeholders, resize, reconnect, and quota attacks;
- agent takeover, resume, stale reports, duplicate sessions, and source conflict;
- corrupt persistence, wrong ownership, symlinks, disk full, and database failure;
- Lua timeout, memory exhaustion, infinite loop, event flood, crash, and restart;
- multi-hour load and multi-day memory soak tests.

Performance reports include p50, p95, p99, allocated bytes, wire bytes, queue
depth, dropped work, and retained memory. A median improvement cannot hide a
tail-latency or memory regression.
