# Invariants

These rules protect users and the split between runtime and client. They hold
whatever shape the code takes. An exception is written beside the code that
needs it and listed under [recorded exceptions](#recorded-exceptions).

Before changing lifecycle, IPC, PTY/VT/input, graphics, agents, persistence,
history, proxy, Lua, plugins or performance, name the change's owner (runtime,
client, core value or worker), its path (interactive, media or observation),
its bounds (bytes, items, time, queue depth), its lifecycle (create, cancel,
detach, reconnect, destroy), its recovery and the test that proves it.

## Ownership

- The runtime owns PTYs, child processes, terminal state, agent truth,
  graphics emitted by children and durable history.
- The client owns layout, focus, hover, selection, scroll, host capabilities
  and physical graphics placements. The runtime may keep a bounded, validated
  layout replica for reconnect; it never becomes the authority over it.
- `telar-core` holds shared types and pure functions, never live state.
- The VT emulator alone defines a child's screen. Observers may read bytes
  but never define or change the screen.
- Client death leaves the runtime valid; reconnect rebuilds cells and graphics
  from snapshots. Runtime death loses live PTYs; do not promise process
  continuity without a supervisor that owns their master descriptors.
- The live runtime model stays in memory. Persistence runs in a worker from
  explicit records and never stores descriptors, PTYs, pointers, closures or
  in-flight work. Live, wire and checkpoint values are separate types so
  private data never leaks through one of them.
- Asynchronous work keeps ids and generations, never pointers. A completion
  looks its owner up again and drops stale results.
- Plugins, observation workers and clients cannot crash or block the runtime
  loop.

## Three paths

**Interactive**: input, PTY bytes, VT state, cell damage, terminal responses.

- Drain the PTY before rendering or observation work.
- Built-in input routing does no filesystem, database, JSON, Lua,
  process-tree, network or plugin work.
- An explicit user binding may call a client-owned Lua callback with hard
  memory, instruction, wall-time and result limits. It receives an immutable
  snapshot and returns validated semantic effects. Runtime and plugin Lua
  never run here.
- Steady state allocates nothing. Fixed buffers and bounded rings absorb
  bursts.
- Obsolete frames are folded, never queued as a replay.

**Media**: KGP payloads, decoded images, compression, image transfer.

- Own queues, workers, quotas, pacing and metrics. Large decode, compression,
  hashing or copies never delay input or cell output.
- Repeated frames are latest-wins where protocol order allows.
- Media failure leaves the text terminal usable.

**Observation**: agent inspection, history, proxy records, search, Git,
analytics.

- Runs behind bounded queues and may allocate or block in its workers.
- Saturation drops or degrades by an explicit policy and never blocks PTY
  traffic. Loss, depth and latency are observable.

## PTY, VT and rendering

- Each PTY burst is drained, parsed, applied, damaged, folded, then published.
- Hidden panes keep parsing but produce no client render work.
- Idle panes and clients schedule no polling or repaint proportional to their
  count.
- Parsers keep state across arbitrary read boundaries; tests split every
  control sequence at every byte.
- Terminal queries have an owner and an expiry. A late response is consumed
  as stale, never forwarded to a pane as input.
- Host input is parsed into semantic events, routed, then encoded for the
  child's active modes. Raw host input is never copied to the child.
- Bracketed paste identifies paste; timing heuristics do not.
- A mouse `down` picks one owner for its whole gesture.
- Focus changes before a newly focused pane receives the triggering event.
- Synchronized output commits one complete frame or expires by an explicit
  recovery rule.

## Presentation delivery

- Preparation borrows the client model; rendering never changes semantic
  state.
- One presentation is in flight per client. Only a successful delivery
  retires the damage it captured; failure and cancellation retire nothing.
  An obsolete delivery cannot consume its replacement.
- A cell ACK is sent after the frame is validated and applied to client
  storage, before host effects. Receiving bytes alone never produces an ACK.
- Attachment generations filter stale frames. Equal frame ids from different
  attachments never clear each other's damage.
- Graphics leases keep retired image bytes charged until the last lease
  returns. Cell ACKs never return graphics credit.

## IPC and multiple clients

- Runtime state is canonical. Each client has its own acknowledged cell and
  graphics state. A slow client never delays PTYs, other clients or
  persistence; when it falls behind, drop intermediate patches and send a
  bounded snapshot.
- Every wire frame has a checked byte limit before allocation or decoding.
- The handshake accepts one exact schema fingerprint. Change it whenever an
  encoding changes.
- Unknown required fields, tags and capabilities fail explicitly.
- Messages carry stable ids and generations; reuse never revives an old
  message.
- One client holds the geometry lease for a PTY. Spectators crop, scale or
  letterbox without resizing the child.
- Host capabilities belong to each client, never to the runtime.
- Remote transport keeps the same framing, bounds and backpressure as local.

## Graphics

- Telar terminates KGP from children; raw child graphics never reach the host.
- The runtime owns child image bytes, ids, generations, placements, quotas and
  protocol responses. The client owns host image ids, placements, clipping,
  z-order, probing and cleanup.
- Image identity is `(pane_id, child_image_id, generation)`, never a sampled
  hash. An image lives while any placement, placeholder, scrollback entry or
  transfer references it.
- Resize, font change, layout change, attach and reconnect rebuild placements
  from canonical state. Child graphics stay clipped to their pane.
- Validate dimensions, multiplication, decoded length, chunks, compression,
  counts and per-pane and global bytes before storing anything.
- File media accepts only validated regular files owned by the user; shared
  memory validates name, length and ownership. Both clean up on unlink and
  crash.
- Every Telar function keeps a cell fallback; KGP only enriches.

## Agents

- Every observation records source, confidence, pane generation, process,
  session, sequence, timestamp and expiry. Official lifecycle reports outrank
  process state, OSC markers and screen heuristics.
- A heuristic may change presentation. It never authorizes input, approval,
  termination, restore or another destructive action.
- Process detection starts from `tcgetpgrp` or an equivalent constant-cost
  signal and inspects processes only after a relevant change.
- Detection and Git status run in observation workers, never in a request,
  render or input handler.
- Persist typed session references, never resume commands. Restore validates
  an official allowlist and rebuilds a fixed argv; reject malformed,
  option-looking, duplicated, stale or wrong-owner references.
- The runtime decides audible transitions; only clients touch host audio.

## History and proxy

- Capture is best effort and never changes forwarded HTTP, HTTP/2, TLS or PTY
  streams. Listeners get whole exchanges through bounded queues; the relay
  never waits for them.
- Bound scrollback, history, query results and pending records by bytes and
  by count.
- Remove secrets before building storable text. Response bodies stay opt-in
  until a redaction and retention policy exists.
- State directories are owner-only. Durable writes are atomic and keep a
  corrupt prior file for diagnosis.
- TLS interception is opt-in, scoped and visible while active. Installing
  system trust is an explicit reversible CLI action with a separate 30-day CA
  whose fingerprint is recorded.
- The proxy secret never leaves the proxy. It lives in the owner-only proxy
  directory, in the service that compares it in constant time and in the
  CONNECT head being authenticated; tunnels and capture queues carry no
  secret. The runtime only asks the proxy for a child environment.
- The proxy observes traffic, never agents: it keeps no provider dialect, no
  lifecycle observation and no agent evidence.

## Lua and plugins

- Configuration Lua is trusted user code whose failures are still contained.
  Runtime configuration is evaluated in a disposable loader and converted to
  validated typed values; no live Lua value enters the runtime.
- A client with Lua callbacks owns one VM generation. Callbacks append bounded
  semantic effects that Zig validates before applying any of them. Lua never
  receives mutable Telar objects or pointers.
- A reload builds and validates a complete replacement before one swap;
  failure keeps the previous generation. Configuration has an API version.
- The default config environment exposes pure constructors and data.
  Filesystem, process, network and control-socket access require an explicit
  user decision.
- A plugin runs outside the runtime, one VM or worker per plugin, with memory,
  instruction, wall-time, output, process and queue limits enforced outside
  the VM. Its callbacks never run inside PTY, render, input or state changes.
- Execution authority binds to a whole-package digest of a pinned revision.
  Discovery, acquisition, trust, enablement and execution are separate
  states. A plugin with filesystem, process or network access is full-trust
  code and the UI says so.

## Local authority

- Socket directories are owner-only and reject wrong-owner, symlinked,
  hard-linked or non-regular endpoints. Peer UID checks do not isolate
  processes of the same user.
- Child panes inherit no runtime socket, token or plugin authority by
  default; the proxy secret is inherited only when the proxy is enabled.
- Persisted state never restores argv, hooks, closures, plugin enablement or
  executable authority without revalidation.
- Remote attach negotiates compatibility before any mutation; installing a
  remote executable requires explicit approval.

## Proof

Every affected rule needs a test or a written proof. The suite covers client
death during every async operation, pane death with work in flight, slow
clients, simultaneous clients with different geometry, floods in visible and
hidden panes, idle cost as pane count grows, parser splits and fuzzing, KGP
attacks, agent conflicts, corrupt persistence and Lua exhaustion. Performance
reports give p50, p95, p99, allocations, wire bytes and retained memory; a
better median never hides a worse tail.

## Recorded exceptions

- **Windows resize** (`lib/console/WindowsResizeWatcher.zig`): one
  constant-cost poll per client, independent of pane count, until console
  records are translated centrally.
