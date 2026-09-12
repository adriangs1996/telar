# Native terminal preparation latency

Measured on 2026-09-12, Apple M3, macOS 26.6.2, Zig 0.16.0. Every reported
sample used a 1900 × 2112 physical-pixel viewport at scale 1.0. The window
manager enlarged the window from its requested initial size; the probe records
actual viewport dimensions.

The baseline is `bef9e3401f7fb7e2d2532ea9784dff9f550afa6c`, with only the
phase markers and GUI trace dump added. Both baseline and optimized binaries
used `-Decho-trace=true -Decho-trace-cpu=true`. Debug is the optimization mode
used by `just app`. Configuration was disabled for both sides, with isolated
runtime/history files and the same `/bin/cat` PTY echo fixture.

## Results

| Case | Samples | p50 ms | p95 ms | p99 ms |
| --- | ---: | ---: | ---: | ---: |
| Debug before | 100 | 195.66 | 200.60 | 202.70 |
| Debug after | 100 | 7.44 | 10.46 | 11.99 |
| Debug after, 1240 background glyphs | 100 | 7.12 | 10.47 | 12.27 |
| ReleaseFast before | 100 | 15.30 | 17.64 | 18.60 |
| ReleaseFast after | 100 | 3.09 | 7.52 | 9.27 |
| ReleaseFast after, 1240 background glyphs | 100 | 3.47 | 8.48 | 15.09 |

Individual samples and viewport metadata are in [samples.json](samples.json).
The Debug empty-scene median improved about 26 times; the ReleaseFast median
improved about 5 times. These are observed runs, not a latency guarantee.
The denser fixture fills 20 rows with 62 characters each and leaves the input
cell empty; it checks that unrelated text does not need shaping again.

The earlier exploratory probe appended text at a timer interval and observed
roughly 385 ms of CPU preparation in Debug and 23.5 ms in ReleaseFast. Those
figures are not the baseline in this table: this probe alternates a single key
with erase and waits for confirmed matching delivery. Do not mix the two
workloads when calculating improvement ratios.

## Measurement boundary

`tools/gui_latency.py` builds a test-only AppKit injector. It sends a native key
event, checks the resulting scene's glyph count, and accepts only successful
Metal completion of that scene's exact token. Only then does it schedule the
next key, after a 30 ms gap. Startup samples are excluded. The injector does
not change the application scheduler or the runtime, and it stops only its
isolated runtime after the window closes.

This measures native key dispatch through successful GPU command completion.
It does not measure physical key acquisition, display scanout or photons.
A TUI host-write benchmark ends at a different boundary, so these results do
not establish superiority over Telar running inside Ghostty.

Opt-in phase traces now cover GUI input, socket send/read, client dispatch,
CPU preparation and GPU completion. The existing recorder is bounded and dumps
only at shutdown. No trace contents or per-frame logging enter production
builds without the tracing flag.

## Why the cost changed

Previously every frame traversed the full grid twice, shaped every cell,
including spaces, and emitted a background quad for every position. Sampling
showed most preparation CPU time inside HarfBuzz.

The text renderer now keeps a bounded cache of owned shaping results.
The terminal renderer retains each cell's compiled geometry using its complete
visual inputs as the key. A cursor-only update recompiles zero cells. Repeated
text reuses shaping across positions and paint styles. Default backgrounds use
the render-pass clear, and spaces retain decorations without invoking shaping.

The preparation cache is independent of delivery state. A failed frame can
reuse prepared geometry on retry; only successful presentation retires client
damage and sends ACKs. Comparing final cell values supports coalesced updates,
resized layouts and reattachment without caching borrowed model pointers.

Both native backends still submit a complete scene. This change optimizes CPU
shaping and cell-geometry preparation; it does not implement partial GPU
framebuffer updates. The full scene remains valid with discarded swapchain
contents and preserves the existing step 9 frame/completion contract.

## Reproduction and regression coverage

```sh
zig build -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/telar-profile
python3 tools/gui_latency.py /tmp/telar-profile/bin/telar /tmp/telar-empty
python3 tools/gui_latency.py /tmp/telar-profile/bin/telar /tmp/telar-dense --dense
```

For ReleaseFast, add `-Doptimize=ReleaseFast` and use fresh output directories.
Keep viewport dimensions and measurement endpoints equal when comparing runs.

Validation completed:

- `zig build test-gui`: 23 tests passed, including cache reuse/eviction, Unicode
  positions, color/style/size changes, differential full-redraw comparisons,
  erasure, wide cells, split geometry, retry, cursor movement, bounded storage
  and allocation-free warm adapter preparation.
- `zig build test-gui-window`: real Metal delivery and native input passed.
- `zig build test`: 123 build steps succeeded; 3264 tests passed, 2 skipped.
- `zig build codestyle` and `zig build check-client-boundaries` passed.

No `src/client` code or runtime wire format changed. Linux uses the same Zig
preparation path, but these GPU latency measurements are macOS-only.

The subsequent [GUI versus TUI-in-Ghostty comparison](gui-vs-tui.md) uses a
shared pixel-verified GPU endpoint and includes Debug and VSync controls.

The subsequent [Metal 4 migration measurement](metal4.md) records the final
display-clock scheduler, a repeated baseline, GPU execution durations and
lifecycle validation.
