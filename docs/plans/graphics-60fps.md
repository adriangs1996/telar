# Graphics at 60 FPS plan

Goal: a full-pane terminal-browser at 4K (3840x2160 RGBA, 31.6 MiB per frame)
presents at the host refresh cap of 60 Hz through telar, with zero media
resets, drops or client resyncs. terminal-browser directly on Ghostty reports
70-80 frames/s written to the tty; the last recorded telar number is
~17.5 images/s at 22.9 MB per frame (commit `0dcbaeb`, 2026-08-24).

Findings that shape the order (verified 2026-09-02, see the session notes in
each phase):

- Memory bandwidth is not the limit. Ghostty itself copies every frame three
  times (`graphics_image.zig:239`, `renderer/image.zig:544`, texture upload)
  and still sustains 70-80. Measured on an M3 with 16 KiB pages for one 4K
  frame: warm memcpy 1.6-1.9 ms; fresh shm object + memcpy 3.7-4.4 ms;
  memcpy into a persistent mapping 1.2-3.1 ms. Page faults on fresh objects
  cost more than the copy.
- The client media pass is the bottleneck. Every graphics message schedules a
  cell draw (`presenter.zig:150-161`); the media pass is armed only after that
  draw at `now + 16.67 ms` (`presenter.zig:211-213`) and re-armed for another
  tick whenever a draw is pending (`presenter.zig:365-369`). Under a
  continuous stream that is three to four ticks per frame, which matches the
  17.5 figure.
- The runtime freezes each generation on the main loop with a 31.6 MiB
  `@memcpy` into a fresh shm object (`attachment/graphics.zig:60`), only
  while the media actor is idle (`delivery/root.zig:488-501`,
  `media_projection.zig:33`), through a single transfer slot
  (`attachment/root.zig:812`). That stalls input dispatch ~4 ms per frame.
- terminal-browser prefers `t=f` over `t=s` (`terminal.rs:433-464`) and, on a
  file-capable host, rewrites eight persistent mmap'd files in place
  (`terminal.rs:509-535`). telar rejects file media
  (`src/backend/media/root.zig:24`), so inside telar it creates a fresh shm
  object per frame.
- Quotas are not a problem: 256 MiB per pane, 128 MiB per screen
  (`src/core/graphics.zig:16-18`). `docs/kitty-graphics.md` still documents the
  old 64/32 MiB values.

Base: `main`. Every wire change follows the golden-corpus discipline in
`src/core/schema/handshake.zig`: corpus entries + version bump. Every phase
keeps the three-budget rule from `docs/engineering-invariants.md`: nothing here
may add work to the interactive path.

Explicit non-goals: PNG decode, Unicode placeholders, remote (socket) clients
above the chunked fallback rate, patching Ghostty the host.

---

## P1. Measure before touching anything

No phase below is accepted on a feeling. Today there is no frames-per-second
counter and no benchmark of the `t=s` → freeze → client path
(`benchmarks/main.zig:128-133` covers `t=d` + zlib at 1080p only).

- Runtime telemetry (`observability/telemetry.zig`): per-attachment
  `graphics_frames_published` with the monotonic timestamp of the last
  publish, `graphics_stage_blocked` split by cause (credit, worker busy, slot
  busy; today `.blocked` is silent, `attachment/root.zig:845`), and
  `diagnostics.Timing` for `media_ingest` (batch sealed → `addImage`) and
  `graphics_freeze`.
- Client telemetry (`resources/telemetry.zig`): `pane_frames_presented`,
  `present_interval` timing per pane, `media_deferrals` (the
  `presenter.zig:365` branch), `shared_expiries` (exists on `Store`, never
  exported), and `shared_retire_latency` from emission to observed consume.
- Benchmark `backend.kitty.shared_frame_3840x2160`: envelope bytes →
  `filterAtomicSharedFrames` → Ghostty VT shm load → `freezeSharedPixels`,
  with the child object created by the harness. Records p50/p99 for each
  stage separately.
- `tools/verify_terminal_browser.py --measure SECONDS`: runs the animated
  fixture at full pane, reads both telemetry streams, and reports frames/s at
  each stage: forwarded by the media actor, published by the runtime,
  presented by the client. Keeps the existing zero-drop assertions. The
  result JSON gains a `frames` block.
- Correct `docs/kitty-graphics.md` quotas.

Exit: baseline numbers for 1080p and the largest local display recorded at the
bottom of this file. No wire change.

## P2. Client: control graphics ride the cell frame

The separate paced media pass exists for the inline budget (256 KiB per pass).
A shared-memory hand-off is ~200 bytes of escapes. Splitting the two removes
the timer hops.

- `CombinedGraphicsWriter` splits into a control writer (shared names,
  placements, placement deletes, image deletes: bounded to a few hundred
  bytes, never pixel data) and a bulk writer (inline chunks, zlib slices,
  toast and icon rasters). Both keep the "whoever opened a transfer owns the
  stream" rule (`presenter.zig:588-616`).
- The cell frame flush includes the control writer inside the same DEC 2026
  update (`screen.zig:201-203` already has the slot; `presenter.zig:537`
  currently clears it). Cells are still composed and written first.
- `presentMedia` no longer re-arms a timer when a draw is pending. It marks
  `media_after_draw` and `completeDraw` runs the bulk pass in the same event.
  The pacer still bounds bulk passes to one per interval.
- `observe` distinguishes graphics-only ingress from semantic changes. With a
  supported host and no fallback change, graphics ingress schedules a control
  flush paced by the same 60 Hz pacer, not a full cell composition.
  `docs/flows/pane-graphics.md` "Budget and bounds" is rewritten accordingly.
- Tests: presenter test feeding shared images at 120 Hz proves control flushes
  at pacer cadence with zero deferrals; ordering test proves bulk still yields
  to pending cells; screen test proves control escapes never interleave with
  cell escapes inside one update. No wire change.

Exit: `present_interval` p99 ≤ 17 ms at 1080p on the `--measure` run.

## P3. Runtime: freeze on the media actor

Move the second copy off the main loop and drop the "only when the actor is
idle" coupling.

- After `addImage`, still on the media actor, the pixels are hot: the actor
  freezes the generation into the runtime-owned object and hands a
  `FrozenFrame { name, metadata, generation }` to the main loop through the
  existing media completion event. One slot per pane, latest wins: replacing
  an unsent frozen frame unlinks the old object.
- `stageNextTransfer` consumes the prepared frame for shared transport instead
  of copying. The `worker == null` gate stays only for the chunked fallback,
  which reads live storage.
- Quota and credit: the actor reserves pane bytes (`reserveManual`) before
  freezing; the main loop applies the byte credit. If credit is exhausted the
  frame is unlinked and `graphics_stage_blocked.credit` counts it.
- Reconnect snapshots keep reading live VT storage; nothing changes for them.
- Tests: attachment tests with a fake actor; frame N+1 completing while N is
  frozen and unsent proves N is unlinked and N+1 published; pane close with a
  frozen unsent frame leaks nothing; `graphics_freeze` timing moves out of the
  main-loop event. No wire change.

Exit: main-loop event dispatch shows no per-frame stall in `--measure`;
`graphics_stage_blocked.worker` is zero.

## P4. Client to host: persistent file ring with an explicit ack

Fresh shm objects cost page faults on both sides and give only an indirect
consume signal (the client polls `shm_open` per media pass,
`kitty.zig:379-396`). terminal-browser's file ring is the proven shape.

- Runtime: per attachment, a 0700 directory under the runtime state directory
  with eight 0600 `O_EXCL` regular files sized on first use per (width,
  height, format). A frozen frame is a memcpy into the next free slot through
  a persistent mapping. A slot is free only after the client reported the
  frame consumed; with eight slots at most seven frames are in flight.
- Wire: `graphics_shared_image` gains `medium` (`shm` | `file`) and the slot
  path. Corpus entries and schema bump. Hosts that fail the file probe keep
  today's `t=s` path unchanged.
- Client: startup probe `a=q,t=f` beside the existing 31/32 probes, capability
  `kitty_file` with the same unknown → supported/unsupported expiry. Emission
  uses `t=f` with `q=0`; the input parser already consumes APC replies, so the
  `OK` for the image id becomes the consume event. Retire and credit return
  happen on the ack, exactly. The pass-counter deadline remains as the safety
  net for hosts that answer nothing.
- Security: the client never opens the files unless it needs the inline
  fallback (read-only mapping). Paths are runtime-chosen, never derived from
  child data. Ghostty's `readFile` validates a regular file; the runtime
  removes the directory on pane close and sweeps stale directories at start.
- Tests: encoding, ack parsing, slot occupancy and reuse, ack-lost expiry,
  fallback to `t=s` on probe failure, corpus.

Exit: `--measure` at the largest local display presents ≥ 60 frames/s with
zero resets, drops and resyncs. `shared_retire_latency` p99 under one frame.

## P5. Accept validated `t=f` from children

terminal-browser then keeps its persistent ring inside telar too, saving the
per-frame object creation on its side.

- `media/root.zig` loading limits enable `.file`. `filterAtomicSharedFrames`
  learns the `t=f` envelope so coalescing keeps working (one newest frame per
  placement per batch).
- Validation before forwarding to the VT: absolute path, `O_NOFOLLOW`,
  regular file, owner is the runtime uid, size equals the declared
  `width * height * bpp`, and byte length under the screen cap. Anything else
  answers `EBADF` on the PTY reply queue and counts `media_unavailable_frames`.
  The child can only point at files it could already read, so the remaining
  open-after-validate window changes nothing about what the pane can show.
- `t=t` stays disabled; the runtime never deletes child files.
- Tests: rejections (symlink, directory, wrong owner, size mismatch, oversize),
  coalescing across rewritten slots, and `verify-terminal-browser` asserting
  the "frames go through a file" log line.

Exit: media actor ingest p99 drops by the fresh-object cost measured in P1.

## P6. Loading churn in the pinned VT (only if P1 shows it matters)

`LoadingImage` grows its buffer 1.5x (~50 MiB fresh per 4K frame) and shrinks
with `toOwnedSlice`. Options, in order of preference: pre-size the loading
list when the declared length is known (patch to the pinned dependency, kept
in `vendor/`), or have the media actor read atomic frames into an exact
reusable buffer and add them to `ImageStorage` directly, bypassing
`LoadingImage` for that fast path only. Decide with the P1 benchmark.

## P7. Gate and documentation

- `docs/performance-gates.md`: the `--measure` run becomes part of the
  exterior behavioral gate with an explicit frames/s floor per display class.
- `docs/kitty-graphics.md` and `docs/flows/pane-graphics.md` describe the
  control/bulk split, actor-side freeze, file ring and ack.
- ADR recording why the client presents graphics inside the cell frame and
  why the runtime hands out files rather than shm objects.

---

## Baseline (P1, 2026-09-02)

Apple M3, Ghostty 1.3.1, terminal-browser `cce10b6`, full-size pane on the
local display (cells 24x66 px), 20 s window, steady-state means:

| Build                      | Frame bytes | Forwarded/s | Published/s | Presented/s |
| -------------------------- | ----------- | ----------- | ----------- | ----------- |
| Debug                      | 37,667,520  | 17.9        | 17.5        | 17.5        |
| ReleaseFast `-Ddiagnostics` | 42,863,040  | 49.6        | 49.6        | 20.0        |

ReleaseFast detail: media ingest 10.9 ms avg (21.7 max), freeze 7.7 ms avg
(24.9 max) on the main loop, 1934 send-loop graphics lanes deferred behind
the media actor, 0 credit blocks, 549 client media deferrals, present
interval 50.6 ms avg (243 max), retire latency 49.4 ms avg. The runtime
publishes two and a half frames for every one the client presents; the rest
are retired unseen when the next generation lands. In Debug the media actor
itself (47.9 ms per batch) is the ceiling, which is why measurement needs
the optimized build.

Benchmark (`zig build bench -- --filter 3840x2160`, ReleaseFast, medians):
child publish 2.3 ms, publish + media ingest 6.4 ms, freeze 2.3 ms per 4K
frame.
