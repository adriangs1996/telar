# Client model cache lines

Which cache lines and pages of `Client` (and the `ClientModel` inside it) the
client's hot paths touch, how many of the bytes loaded they use, and what
changed. Branch `perf/client-model-cache-lines` from `main` at `5c386502`.

## Measurement

`zig build build-cache-trace` builds two probes that drive the real adapters
through their event loops and mark one window per event:

- `telar-cache-trace-tui` (`src/frontend/client/tests/cache_trace.zig`): the
  `TerminalAdapter` over a socket pair with its runtime read worker, TTY
  reader and scheduled draws. Windows: the read worker decoding a frame,
  `frame/server`, `frame/sent`, `frame/draw`, then a key: `key/read_worker`,
  `key/input`, `key/sent`.
- `telar-cache-trace-gui` (`src/gui/tests/cache_trace.zig`): `GuiAdapter`
  through `update` and `draw` as its host calls them, including
  `frame/presented`.

Both run six warm iterations of a one-cell frame and one key, then trace the
seventh, with four tabs in the terminal probe. `lib/touchtrace` marks the
windows with Valgrind client requests. `touchrange/lk_main.c` is the Valgrind
tool behind them; it replaces lackey's main. It keeps a byte bitmap per
registered range (`Client`, the adapter, the focused pane) and prints the
runs each window read or wrote. `analyze.py` turns the runs into distinct
128 B and 64 B lines, 16 KiB and 4 KiB pages, bytes used against bytes loaded,
and the field behind each line. Addresses are normalized so the adapter
starts a 16 KiB page, as a macOS allocation of that size does.

```sh
docker build -t telar-touchrange docs/performance/client-model-cache/touchrange
docker build -t telar-touchrange-gui -f docs/performance/client-model-cache/touchrange/Dockerfile.gui docs/performance/client-model-cache/touchrange
docs/performance/client-model-cache/trace.sh NAME OUT
python3 docs/performance/client-model-cache/analyze.py OUT/NAME-tui --against OUT/OTHER-tui --fields frame/server
```

Traces run on Linux arm64 (the `ClientModel` and `Client` sizes match macOS
arm64: 1,237,048 and 1,856,592 bytes at the base). Two runs of the same tree
give identical counts and digests. Windows that span a hand-off between
threads can absorb a worker's accesses depending on scheduling. That hits
the adapter range (its inbox), not `Client`, and the tables below only use
`Client`.

**Oracle.** Each probe hashes every byte the runtime received. The terminal
probe also counts the bytes written to the terminal. Every accepted change
keeps both: terminal `53c61a88…56fc` (14 messages, 3,851 terminal bytes),
native `23944a05…5dc1` (16 messages). The renderer probe
(`probe_verify.sh`) gives identical frames in all twelve modes, base against
final.

**Timing.** New `telar-benchmarks` cases drive the shared client without
threads: `frontend.client.frame_event` (a one-cell frame through `update`,
ack, `flush`, the job queue and the write completion),
`frontend.client.key_event`, `frontend.client.request_group_query` and
`frontend.client.present_frame` (capture, `begin`, `complete` and `retire` of
one pane). All pairs are alternated, ReleaseFast, on an Apple M-series host
(128 B lines, 16 KiB pages, 64 KiB L1d, 4 MiB L2).

## What the hot paths touched

At the base, `Job` was 17,312 bytes and the 32-slot `to_workers` ring was
554 KB of `Client`. Each runtime read or write pushed and popped a whole
`Job`. `frame/server` spent 271 of its 341 lines there, and `key/input` 136
of 175. The rest of the waste was other whole-union copies:
`ServerMessage` (4,152 bytes for a 168-byte pane frame), and in the draw the
presentation flight (3,984 bytes), its geometry (1,608) and, in the GUI, a
copy of every pending request (16 KiB) each frame.

## Changes

| Commit | Change |
| --- | --- |
| `588419a9` | `build-dod-probe` compiled again (a removed `deinit`); needed for the baseline |
| `5a62c787` | the terminal probe, touchrange tool, analysis and benchmark cases |
| `5a5c1ca2` | `Job` keeps runtime reads, writes and timers; `BackgroundJob` queues the jobs that carry a request copy |
| `f36e9126` | `receiveServerMessage` dispatches the transport's message by pointer |
| `61536f74` | `decodeServerInto` decodes into the transport's slot |
| `eed9f1ff` | `lib/touchtrace` and the native probe |
| `04749618` | `Tracker.has`/`hasPane` visit live entries in place and stop after `count` |
| `682477cc` | presentation flights copy only `panes[0..len]`; the GUI reads the flight token by pointer |

### Client lines touched (128 B), pages (16 KiB) and bytes used

Terminal, base (`5a62c787`) against final (`682477cc`):

| Window | Lines | Pages | Bytes used | Used / loaded |
| --- | --- | --- | --- | --- |
| frame/read_worker | 33 → 3 | 1 → 1 | 4,168 → 185 | 0.99 → 0.48 |
| frame/server | 341 → 42 | 20 → 17 | 39,971 → 1,367 | 0.92 → 0.25 |
| frame/sent | 29 → 29 | 13 → 13 | 803 → 811 | 0.22 → 0.22 |
| frame/draw | 87 → 76 | 16 → 16 | 7,421 → 5,910 | 0.67 → 0.61 |
| key/input | 175 → 40 | 19 → 17 | 18,371 → 1,091 | 0.82 → 0.21 |
| key/sent | 29 → 29 | 13 → 13 | 819 → 827 | 0.22 → 0.22 |

Native, base (`5a62c787` with the native probe applied, decoding with
`RuntimeMessage.decode` as that tree does) against final. The same probe on
that tree reproduces the terminal base numbers above exactly.

| Window | Lines | Pages | Bytes used |
| --- | --- | --- | --- |
| frame/read_worker | 33 → 3 | 1 → 1 | 4,168 → 185 |
| frame/server | 346 → 46 | 21 → 18 | 40,185 → 1,597 |
| frame/sent | 36 → 36 | 17 → 17 | 905 → 913 |
| frame/draw | 210 → 63 | 17 → 17 | 22,195 → 2,545 |
| frame/presented | 83 → 72 | 16 → 16 | 7,287 → 5,776 |
| key/input | 177 → 43 | 20 → 18 | 18,365 → 1,093 |
| key/sent | 36 → 36 | 17 → 17 | 921 → 929 |

The job split took `frame/server` from 341 to 72 lines and
`key/input` from 175 to 40. Dispatch by pointer took `frame/server` to 42,
and decoding in place took the read worker from 33 lines to 3. The request
queries took the native draw from 211 lines to 88, and the flight copies
took it to 63.

### Paired timing, base against final

`A` is `5a62c787` (the first build with the client cases), `B` is
`682477cc`; 7 pairs, 6 for `schema.` and `backend.`.

| Case | A | B | Paired | Wins |
| --- | --- | --- | --- | --- |
| frontend.client.frame_event | 1,329 ns | 105 ns | -92.1% | 7/7 |
| frontend.client.key_event | 513 ns | 44 ns | -91.5% | 7/7 |
| schema.decode.one_cell | 85 ns | 16 ns | -81.2% | 6/6 |
| schema.decode.full_screen | 85 ns | 16 ns | -81.2% | 6/6 |
| schema.decode.fragmented | 459 ns | 395 ns | -13.9% | 6/6 |
| frontend.pipeline.one_cell | 142 ns | 71 ns | -50.0% | 7/7 |
| frontend.pipeline.fragmented | 9,460 ns | 9,332 ns | -1.4% | 7/7 |
| frontend.multiplexer.patch_one_cell | 215 ns | 175 ns | -18.7% | 7/7 |

The cases added later were measured on their own commit against the same
tree without the change:

| Case | Before | After | Paired | Wins |
| --- | --- | --- | --- | --- |
| frontend.client.request_group_query (one request pending) | 364 ns | <1 ns | -100% | 9/9 |
| frontend.client.present_frame | 413 ns | 390 ns | -5.8% | 7/7 |

Every other `frontend.`, `schema.` and `backend.` case is within noise. No
loss was consistent across reruns: `chrome.tabs_64` went +0.9% (0/7), then
-1.0% (6/7); `backend.delivery.flush_idle_1x32` +3.4% (2/6).
`frontend.layout.directional_focus` lost 1.5 to 2.2% (2 ns, 0/7). Its
`WorkspaceLayout.focusDirection` has identical normalized disassembly in both
builds, so that is placement. The renderer probe (`retained`, `sparse`,
`full` at two sizes, 7 pairs) moved between -0.6% and +0.9% with 2 to 5 wins.

One full-suite run showed `chrome.tabs_8` at 51 µs instead of 17.7 µs, and
the same happened to both sides of an earlier pair. It did not reproduce:
alone, in the full suite with and without `--json`, and in a fresh 7-pair
run (17,723 against 17,747 ns, 4/7). Cause not established; it was a state
of the host, not a build.

## Disassembly

- `Client.update` inlines `receiveRuntime`; before the pointer dispatch it
  called `memcpy` for the whole `ServerMessage` on every runtime message.
- `self.active = null` on a `?Flight` compiles to a `bzero` of all 3,984
  bytes on arm64 ReleaseFast, so `complete` still writes the whole flight.
- Default-initialized `PresentationCommit` values (`.{}` with an `undefined`
  array) are zero-filled with `memset` in `presentation_delivery.capture`.
- A change inside `Tracker` altered LLVM's inlining of
  `synchronizeSidebarAnimation` into `receiveServerMessage`. That is how the
  iterator variant cost `frame_event` 1 ns.

## Rejected variants

- **Dense group column in `Tracker`.** `has` read 144 bytes regardless of
  pending requests. It grew `RequestLifecycle` by 144 bytes, which moved
  every later `ClientModel` field. Several windows then touched 1 to 6 more
  lines for the same bytes, and `frame_event` lost 2.9% (0/7).
- **An iterator struct over live entries.** Same lines as the accepted
  version, but it changed the inlining above (`frame_event` +1.0%, 0/9).
- **Count-guarded full scan.** An early return when `count == 0` and a
  pointer loop. With one pending request it still read the null flag of all
  72 slots.

## Findings left for a decision

1. **Scattered revision counters.** `ClientModel.version()` reads 28
   counters spread over the struct. Counters alone put 7 to 14 lines and 3
   to 6 pages of 16 KiB into every window above (terminal `frame/sent`: 14
   of 29 lines, 6 of 13 pages). A `revisions: Revisions` struct, the shape
   `docs/architecture.md` already sketches, would hold the 21 top-level
   counters in 168 bytes (two lines). It renames 337 references, and the
   warm benchmarks here cannot show its gain because the whole working set
   sits in L1. The cost it removes shows up with a cold cache, in a client that
   renders between events, or several machines' clients in one process.
   Only the adapter-level cold scenario would show it.
2. **Presentation values by copy.** `present_frame` still spends most of its
   samples in `memcpy` and `memset`. Two causes remain, the `?Flight` nulling above and a
   `PresentationCommit` (2,088 bytes) passed by value through `capture`,
   `begin`, `complete`, `commitPresentation` and `retire`. Removing them
   means changing those signatures in the model, the client, both adapters
   and the headless fixture.
3. **`Message` size.** `plugin_result` makes `client.Message` 4,432 bytes,
   so every adapter inbox slot (`ClientEvent`, 4,448 bytes) and every
   publish and receive moves 4 KiB for events that carry a pointer. Only one
   plugin action is in flight at a time (`PluginExecutionState`), so its
   `WorkerResult` could live in a client-owned slot the job points at.
4. **`to_background` footprint.** The background ring keeps 32 slots of
   `BackgroundJob` (17,296 bytes each, `WaitArgs` with a copy of the plugin
   overrides), 554 KB of `Client`. It is cold now, but it is still a third of
   every `Client` the machines plan would keep in its array.
5. **`Panes.iterateConst` and `countIn`** scan all 64 record pointers (5
   lines per call) and dereference every live pane, several times per draw.

## Validation

`zig build codestyle`, `check-client-boundaries`, `check-model-boundaries`,
`check-programs`, `check-library-reexports`, `cross` and `test-gui` pass.
`zig build test` fails on the base (`588419a9`) and on the final tree with
the same tests except one. Final passed 2,603 of 2,612, base 2,601 of 2,609.
The shared failures are the two file-URI editor tests in
`client.tests.host_interaction`, the `localsocket` listener tests (the
session's `TMPDIR` makes socket paths exceed `sun_path`), three runtime
startup tests and `lib-imaging`. The one extra failure is in `lib/mermaid`'s
helper deadline tests. Nothing in this branch touches that library, and
three reruns failed a different test of the same group each time.
