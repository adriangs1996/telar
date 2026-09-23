# DOD pass 2: layout, comparisons and retained work

Measured on 2026-09-23 on `refactor/client-world-storage` over `e11b1b7f`.
Apple M3 (4P+4E), macOS, Zig 0.16.0, ReleaseFast, native CPU. Baseline `A` is
`e11b1b7f`; candidate `Z` is the working tree described here. Timings are
paired and alternated (A, Z, Z, A, ...); "wins" counts pairs where Z was
faster. The host was not idle; pairs, not absolute values, are the evidence.

## Correctness fix

`GenericSlotIndex` never reclaimed tombstones. With 4 live keys and one
create/remove per cycle, capacity 128 ran out of empty slots after 774 cycles
and `get` of an absent key looped forever (reproduced; the new churn test hung
on the old code). It now uses backward-shift deletion and bounded probes.
`PaneStore`, `AttachmentStore`, `MultiplexerModel.pane_index` and the layout
view index use it. A randomized test checks it against a reference map.

## Changes

| Change | Where |
| --- | --- |
| Canonical `Color` (`extern struct { kind, value }`, unused channels zero) so a `Cell` has no undefined bytes; `Cell.eqlPublic` compares 32 bytes | `core/ui/Color.zig`, `core/ui/Cell.zig` |
| Per-architecture reduction chosen from disassembly (below) | `core/ui/Cell.zig` |
| Reserved-run cell encoder: no per-byte checks when the worst case fits; colors stored as one word | `core/schema/frame_support.zig` |
| Blit: printable ASCII stored straight into the row when it is inside the clip; one style translation per style id per row | `backend/pane/blit.zig` |
| Agent repository: dense key array and occupancy mask instead of scanning 64 x 8,360 B aggregates | `backend/agent/Repository.zig` |
| Direct CUP/SGR digit formatting (falls back to `print` near a full buffer) | `frontend/presentation/screen_support.zig` |
| GUI cells: background flag in metadata, row slices, ink pass skips cells without ink, geometry split into dense `primary` (background + first ink) and cold `overflow` | `gui/render/*` |
| GUI cells compared in place in the pane buffer; only selected cells are copied | `gui/render/TerminalRenderer.zig` |
| Atlas table for one-byte primary ASCII runs: skips procedural parsers, shaping cache and glyph map with the same placement arithmetic | `gui/text/GlyphAtlas.zig`, `AsciiGlyphs.zig` |
| Retained thread message heights keyed by text fingerprint and every layout input (messages mentioning `mermaid` are not cached) | `gui/widgets/MessageHeights.zig`, `ThreadMessage.zig` |

## Results

GUI terminal preparation (`telar-dod-probe`, 7 pairs, 3,000 draws, full
redraw 1,000). All 12 modes produce identical quad and atlas SHA-256 digests
for 88 frames each.

| Case | A µs | Z µs | Median paired | Wins |
| --- | ---: | ---: | ---: | ---: |
| retained 80x40 | 36.33 | 15.77 | -56.5% | 7/7 |
| retained 160x40 | 72.76 | 31.19 | -57.4% | 7/7 |
| sparse 80x40 | 36.33 | 15.70 | -57.0% | 7/7 |
| full 80x40 | 148.04 | 64.82 | -56.0% | 7/7 |
| full 160x40 | 295.50 | 128.04 | -56.7% | 7/7 |
| two panes active 80x40 | 36.31 | 15.94 | -56.9% | 7/7 |
| cursor 80x40 | 38.11 | 15.75 | -58.7% | 7/7 |
| selection 80x40 | 46.72 | 24.96 | -46.6% | 7/7 |

Agent transcript, 32 messages (resolve + draw, height cache off/on, 2 runs
each): repeated text 67-73 µs to 49-57 µs; every word distinct (2,036 words,
beyond the shaping cache) 2.60-2.85 ms to 0.30-0.40 ms per frame.

Interactive benchmarks (`telar-benchmarks`, 6 pairs, median ns/op):

| Case | A | Z | Median paired | Wins |
| --- | ---: | ---: | ---: | ---: |
| backend.damage.one_cell | 572 | 98 | -82.7% | 6/6 |
| backend.damage.fragmented | 17,696 | 3,498 | -80.2% | 6/6 |
| backend.damage.full_screen | 6,454 | 3,240 | -49.8% | 6/6 |
| backend.frame.fragmented | 22,028 | 4,582 | -79.2% | 6/6 |
| backend.blit.full_screen (new; baseline is the tree before the blit change) | 35,498 | 25,846 | -27.2% | 6/6 |
| schema.encode.fragmented | 2,845 | 1,104 | -61.1% | 6/6 |
| schema.encode.full_screen | 29,108 | 8,138 | -72.3% | 6/6 |
| frontend.pipeline.fragmented | 18,848 | 10,497 | -44.2% | 6/6 |
| frontend.pipeline.full_screen | 71,163 | 63,872 | -10.2% | 6/6 |
| frontend.flush.cursor_only | 62 | 48 | -22.6% | 6/6 |
| frontend.multiplexer.compose_four | 43,570 | 27,220 | -37.5% | 6/6 |
| frontend.client_ui.chrome.tabs_1 | 21,045 | 15,550 | -26.1% | 6/6 |
| frontend.multiplexer.patch_one_cell | 186 | 194 | +4.0% | 0/6 |
| schema.decode.one_cell | 65 | 74 | +14.1% | 0/6 |
| schema.decode.full_screen | 64 | 75 | +16.3% | 0/6 |

The decode rows are not caused by these changes: `decodeServer` and
`decodeBody` disassemble to identical instruction streams in A and Z (only
addresses and line-number constants differ), so the difference is code
placement. `patch_one_cell` does execute the new comparison, for one cell;
no cause for its 8 ns is established.

Agent repository lookup (standalone kernel with the real 8,360 B slot, two
agents, misses as for terminal panes): `discover` for 10 panes went from about
400 ns to about 30 ns per call. It runs on every PTY ingest batch.

## Disassembly findings

- `@reduce(.And, a == b)` over bytes lowers on AArch64 to CMEQ, BIC, EXT,
  ZIP1 and ADDV per 16 bytes; XOR, ORR and UMAXV is shorter. On x86-64 the
  opposite holds: SSE2 gives PCMPEQB, PAND, PMOVMSKB and AVX2 gives VPXOR,
  VPTEST, while a max reduction becomes PSHUFD/PMAXUB rounds. `Cell.eqlPublic`
  selects per architecture at comptime; the three lowerings were checked for
  `x86_64` baseline, `x86_64_v3` and `aarch64`.
- A byte view (`std.mem.asBytes(cell).*`) of a cell whose fields were already
  loaded made LLVM rebuild the second 16 bytes with seven `ld1.b` lane
  inserts. Pointer casts to whole vectors give two `ldp`.
- Mutating a copied cell (selection inversion) split it into scalars and
  spilled key words to the stack. The renderer now compares the buffer cell
  in place and copies only selected cells.
- XOR-OR over four `u64` became four compare-and-branch pairs with stack
  reloads; it was rejected (+14%).
- Vectorizing the rect key compare was -3% on warm draws and +2-3% on full
  redraws because the rect vector is assembled with lane inserts; rejected.
- Whole-quad stores in `CellMesh.replace` were -3% on full redraws and +6% on
  sparse draws, reproducibly; rejected. Branch hints and an out-of-line
  repaint path were also neutral or negative.

## Validation

`zig build test`: 3,029/3,031 passed, 2 skipped. `zig build test-gui`: 757/757.
`cross`, `codestyle`, `check-client-boundaries`, `check-model-boundaries` and
`check-programs` pass. The touched core files' tests also pass compiled for
`x86_64-macos` baseline and `x86_64_v3` under Rosetta. No x86 timing is
claimed: Rosetta translates the code.

New tests cover index churn and a reference model, reserved versus checked
encoding, direct versus `setCell` blit rows, direct versus `std.fmt` escapes,
cached versus shaped ASCII glyphs for all bytes, styles and fractional
positions, and cached versus fresh message heights through streaming and
resizing.

## Not changed, with measurements

- `forwardInput` calls `tcgetpgrp` on every keystroke to classify history
  input. On this M3 it costs 2.7-2.9 µs per call on a real session PTY
  (`forkpty`, 200,000 calls). Sampling it elsewhere changes which edits count
  as shell commands, so it needs a decision rather than an optimization.
- Clearing only the drawn chrome regions instead of the whole TUI scratch
  buffer requires proving which regions are read afterwards; not attempted.
