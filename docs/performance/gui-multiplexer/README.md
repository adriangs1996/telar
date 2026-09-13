# GUI multiplexer integration

The reference is commit `4368e07c`, before the native multiplexer integration.
The integration branch is `feat/gui-integration`. The runtime is unchanged.
The TUI's host URL worker moved into the common client and the TUI now imports
that implementation. Shared-client additions expose semantic input operations;
GUI composition and native event ownership remain in `src/gui`.

## Functional verification

Machine-readable counts, revisions and local log paths are in
[validation.json](validation.json). The macOS general suite passed 3,381 tests
with two platform skips, including 862 common-client and 604 TUI tests. The
baseline general suite passed 3,289 tests with two skips; its command did not
include the separate GUI suite. After the final input fixes, the macOS native
checks passed all 101 GUI tests, the Metal window probe, style and boundaries.
The final Linux run passed all 3,293 general tests and 100 GUI tests, with one
platform skip, across 152 successful build steps.
These counts represent the recorded runs, not a multi-day stability claim.

The [macOS session probe](../../../tools/gui_multiplexer.py) and
[Wayland matrix](../../flows/gui-multiplexer-linux.md) drive real windows and
verify shell receipts, identities and PTY dimensions. Both Linux prefix
configurations passed navigation and clipboard round trips. Clipboard worker
failure and shutdown also passed with AddressSanitizer, UndefinedBehaviorSanitizer
and leak detection enabled.

The final macOS session run is recorded in
[macos-session.json](macos-session.json). It checks five distinct live shells,
both split directions, pane fullscreen and restoration, pointer focus, sidebar
visibility, tabs, workspace naming and goto. Closing and reopening the window
preserved the shell identities and the original split dimensions.

## Composition work and storage

The allocation test uses a 160 by 60 cell host with eight styled terminal panes,
four tabs, three workspaces, eight agent cards and four notifications. It checks
the normal scene and an open goto picker, each over 120 warm redraws while
cycling background opacity between zero, one half and one.

Each variant had zero new adapter allocations, zero allocated bytes, zero new
shaping calls, zero additional raster attempts and zero repainted terminal
cells. The atlas and quad counts stayed unchanged. This measures the Zig
composition owners instrumented by the test, not every allocation inside the
operating system, font library or GPU driver.

ASCII labels have dedicated shaping-cache slots. A bounded negative cache
remembers glyphs that cannot fit in the atlas, avoiding repeated raster work
while allowing smaller glyphs to fill the remaining space. Hit maps have two
bounded snapshots. Publishing a delivered frame changes an index; a failed
frame preserves the previous controls. Receipt ACKs still advance independently
of GPU completion.

The frame's quad reservation increases to cover overlapping controls. At the
test geometry it reserves 352,704 quads of 48 bytes, or 16,929,792 bytes. The
baseline reserved 232,192 quads, or 11,145,216 bytes. The additional 5,784,576
bytes are reserved at geometry changes. These are calculated capacities from
the source, not sampled process RSS. They exclude retained cell meshes, atlas
storage and native GPU buffers.

## Latency method

`tools/gui_composition_latency.py` compares release binaries using the existing
Metal marker-pixel probe. The interval starts when the GUI receives committed
text and ends at successful GPU completion of a frame containing the expected
pixel. It excludes physical keyboard delivery and display scanout. The probe
adds the same pixel readback to both variants.

The host is an Apple M3 with 16 GiB of memory, macOS 26.6.2 build 25G83 and
Zig 0.16.0. Both binaries use `ReleaseFast`.

Each run discards 20 warm-up samples. Baseline and candidate runs alternate order
in an ABBA sequence, with the same 1000 by 700 pixel render target and the same
configuration. The sidebar is enabled. The baseline ignores native chrome and
gives its shell 111 by 35 cells; the integrated GUI reserves bars and sidebar,
leaving 69 by 33 cells. This compares application behavior at a fixed window
size, not identical terminal work areas. Compilation and VM tests are paused
during collection. Existing desktop applications are not stopped.

### Final series

[final-comparison.json](final-comparison.json) compares `4368e07c` with the final
code snapshot `f3d6cf53`. Four rounds of 250 measured samples yield 1,000 samples
per variant. Every expected echo was observed; no sample was discarded after
warm-up.

| GUI | p50 | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 3.075 ms | 5.702 ms | 8.309 ms | 30.791 ms |
| Integrated | 2.723 ms | 5.286 ms | 9.377 ms | 29.722 ms |

The integrated GUI has a lower median and p95 in this run, while p99 is
1.068 ms higher. Eight baseline samples and ten candidate samples exceeded
10 ms. Candidate p99 ranged from 5.873 to 23.841 ms across the four rounds;
baseline p99 ranged from 7.741 to 11.743 ms. The final candidate round accounts
for most of its tail increase. This comparison does not isolate the cause of
those slow completions or establish that the integrated GUI is faster overall.
The echo workload has one pane; the eight-pane composition test above checks
warm work and bounds separately.

Reproduce with two release binaries and a new temporary directory:

```sh
python3 tools/gui_composition_latency.py BASELINE CANDIDATE /tmp/NEW-DIRECTORY \
  --samples 250 --rounds 4 --viewport 1000 700
```

### Initial series

The first short series is retained in
[initial-comparison.json](initial-comparison.json). It compares `4368e07c` with
intermediate snapshot `c0eb07b7`, with 300 measured samples per variant:

| GUI | p50 | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 2.788 ms | 5.102 ms | 6.600 ms | 24.921 ms |
| Integrated, intermediate | 2.626 ms | 5.678 ms | 17.585 ms | 26.487 ms |

The median stayed in the same range, but the candidate's p99 was higher in this
series. Those results do not establish an improvement or exclude a tail-latency
regression. The raw samples are retained rather than dropping slow observations.

The latency probe does not count wire bytes, sample queue occupancy or report
whole-process retained memory. The GUI still has one presentation in flight
and coalesces newer model state. The functional tests separately exercise input
saturation, transfer quotas and failed presentation. The Linux VM uses software
Vulkan for functional validation; its timings are not a native-GPU comparison.
