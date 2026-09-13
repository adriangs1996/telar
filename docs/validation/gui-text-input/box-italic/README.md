# Connected box drawing and italic overhang

Validated on 2026-09-13. Baseline `b2d1c16b`; final production code `69157933`.
Changes are confined to GUI text and composition, tests, probes and documentation.
Runtime, protocol, common client and TUI source are unchanged.

The baseline uses font bitmaps for box drawing, leaving gaps between rows with
configured line spacing. It also clips primary-font bitmaps to each cell,
discarding italic overhang. The correction draws U+2500..U+257F against the full
cell grid and retains natural font ink until composition clips it at the pane
boundary. Block cursors precede ink; color follows the owning cell. See the
[drawing path](../../../flows/gui-procedural-glyphs.md).

## Correctness

| Check | macOS / Metal | Linux / Wayland / Vulkan |
| --- | --- | --- |
| GUI suite | 169 passed | 168 passed, 1 macOS-only test skipped |
| Source style and common-client boundaries | Passed | Passed |
| Native rendering fixture | Connected frames and complete italic ink | Connected frames and complete italic ink |
| Input check | Neovim line 1 to 12 after one press and ten injected repeats | Held `j` repeats and stops on release |

[macOS checks](macos-checks.txt), [Linux checks](linux-checks.txt) and the
[Linux native window check](linux-window-checks.txt) retain build output. The
window check also exercises rejected-scene cleanup. The Wayland fixture enables
Vulkan validation and reported no validation warnings.

Before the fix, all five new box integration tests fail, as do four italic
regressions: [box failures](box-regressions-before.txt),
[italic failures](italic-regressions-before.txt). The final suite covers:

- All 128 box characters, stroke joins, non-overlapping faint intersections,
  fractional and tiny cells, rounded corners and diagonals.
- Existing Braille, fallback fonts and text behavior; combining and
  variation-selector clusters remain on the font path.
- Italic and bold-italic `New` with DejaVu Sans Mono, with and without macOS
  thickening, and line-height ratios 1.4 and 0.75.
- Natural bitmap retention, pane clipping, selection, cursor colors and wide
  cells; retained updates match a complete rebuild.
- Repeated warm updates with allocation disabled, cache/atlas saturation,
  stable masks and bounded failure handling.
- The bounded curve raster matches the complete calculation byte for byte.

The native fixtures use unpatched DejaVu Sans Mono: macOS uses size 22, line
height 1.4 and thickening at strength 255; Linux uses size 16, line height 1 and
FreeType. Both display the shared sample from `tools/gui_rendering_sample.py`.
Visual inspection confirms the connected rounded frame and heavy/double boxes,
plus intact italic text. The fixtures reproduce the reported glyphs; they do not run Codex itself
or establish pixel equivalence to Ghostty.

| Platform | Before | After |
| --- | --- | --- |
| macOS | [Font strokes and clipped italics](macos-before.png) | [Connected strokes and natural ink](macos-after.png) |
| Linux | [Font strokes and clipped italics](linux-before.png) | [Connected strokes and natural ink](linux-after.png) |

Input results are recorded in [macOS JSON](macos-after.json) and
[Linux JSON](linux-after.json). The macOS driver injects AppKit repeat events;
Linux uses a virtual hardware key hold. Each probe owns and cleans up its own
runtime and PTY.

## Resource and CPU bounds

Straight box strokes use the existing white texel and at most 21 disjoint ink
quads. Background and two decorations still fit the existing 24-quad cell limit.
They never enter font shaping or rasterization. The integration test changes
all 128 characters twice after warmup without additional shaping, rasterization,
atlas mutation or allocator calls.

Rounded corners and diagonals use the existing 1024-by-1024 alpha page. Their
fixed cache occupies 3,824 bytes and has 56 entries, including failed admissions.
Seven reserved 16-by-32 masks occupy 3,584 useful texels; atlas reservations
including their padding occupy 3,927 texels. Masks are never overwritten while
retained geometry may refer to them. Saturation or geometry above 256-by-256
uses the reserved masks, sacrificing shape fidelity while preserving bounded
work and visible output. The existing atlas size and cell/frame quotas do not
increase.

A [reproducible CPU harness](curve_measurement.zig.txt) interleaves the original
full-cell curve calculation and the bounded calculation 31 times in ReleaseFast.
It consumes the raster output through `doNotOptimizeAway`. On this Apple M3,
the median cost for all seven masks at 26-by-71 fell from 435 to 157 microseconds;
at the 256-by-256 limit, from 8.71 to 2.71 milliseconds. These are approximate
CPU raster costs measured with other builds active, excluding atlas packing,
GPU upload and presentation. They are not input-latency measurements.
[Raw output](curve-raster-cost.txt) also includes a constant-key cache loop;
that loop is not representative of complete terminal rendering.

Pane composition retains each glyph's full bitmap and performs UV adjustment
only when the quad crosses the pane boundary. Quads wholly inside preserve their
coordinates directly. Block cursor composition no longer duplicates its cell's
ink. No GPU shader, texture count or IPC change is needed.

## Input-to-GPU reference

The existing `tools/gui_composition_latency.py` probe compared the baseline and
final binaries on an Apple M3, macOS 26.6.2, with Zig 0.16.0 Debug builds. Both
used a 1000-by-700 viewport and a 69-column, 33-row PTY. Three alternating rounds
produced 300 measured samples per binary, discarding 20 warmup samples per run.
Other agent builds and VM probes had finished before this measurement.

| Milliseconds | Baseline | Final |
| --- | ---: | ---: |
| p50 | 5.097 | 5.007 |
| p95 | 8.428 | 8.418 |
| p99 | 14.499 | 17.285 |
| Maximum | 34.542 | 29.842 |

The endpoint starts at committed text and ends when the GPU completes a frame
whose marker pixel matches the expected child output. It excludes hardware key
delivery and physical display scanout. All six runs had zero probe failures.
The median and p95 stayed close. Aggregate p99 increased by 2.79 ms, while
individual-run p99 ranged from 10.15 to 23.56 ms in the baseline and 10.37 to
18.46 ms in the final binary. This sample does not isolate the cause of that
tail variation. It is a desktop latency reference, not a renderer-only CPU
measurement or a comparison with Ghostty.

[Complete samples, per-run summaries and binary hashes](latency-comparison.json)
are retained. The latency probe does not measure wire bytes, queue depth, drops
or retained memory. Allocation and resource bounds above come from the dedicated
tests and the cache layout measurement.

```sh
python3 tools/gui_composition_latency.py \
  /tmp/telar-glyph-baseline/bin/telar /tmp/telar-glyph-candidate/bin/telar \
  /tmp/telar-box-italic-latency --samples 100 --rounds 3 --viewport 1000 700
```

## Reproduction

Use new output directories and the Linux binary built in the isolated Wayland
VM for its probe:

```sh
zig build install test-gui codestyle check-client-boundaries
python3 tools/gui_text_input.py zig-out/bin/telar /tmp/telar-box-italic-macos --rendering
python3 tools/vm/vm.py build install test-gui codestyle check-client-boundaries
python3 tools/vm/gui-key-repeat-test.py /tmp/telar-box-italic-linux --rendering
```
