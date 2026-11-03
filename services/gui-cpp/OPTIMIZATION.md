# C++ GUI optimization handoff

The new complete-stack performance task is defined in
[cpp-performance-flows.md](../../docs/cpp-performance-flows.md). It covers both
runtimes and GUIs, with native 120 Hz smoothness where supported. The historical
GUI-only findings below are inputs to that task, not acceptance of the new matrix.

The [local optical-text optimization](#local-optical-text-optimization-2026-11-02)
below removes a confirmed C++ terminal-rendering bottleneck. It is measured against
the preceding C++ renderer and checked against original Zig pixels; complete-stack
performance against Zig and sustained 120 Hz presentation remain unqualified.

The remaining scoped task is the measured performance regression against the Zig
GUI. Graphics/attachments and native blur have shipped in Preview27. Preserve
functional and visual behavior, explicit allocators, compile-time dependency
selection and the application/platform boundary. The wider feature backlog and
runtime/CLI/plugin-worker migration are separate work.

Start from a new checkout of the current committed source and configure its own
dependencies, builds and measurement tools. Adrian explicitly requested this on
2026-11-02. The previous Personal checkout, previews, frozen binaries, raw results,
local runner adaptations and Linux VM were deleted. This document preserves findings
and rejected approaches; it is not a prepared environment to resume.

## Source and measured candidate

| Checkpoint | Identity and state |
| --- | --- |
| Last production change measured | `a1ea73a89465d1144921e6a924436085601c5537`, native blur and Preview27 |
| Final Personal branch | `089a07dcd6cd719f80c56625652afacb87060635`, benchmark report after artifact cleanup |
| Integration into this branch | `36adb7d4f7be59c79323396db4fd8ac54142f48d` |
| Historical C++ measurement | Preview27, SHA256 `eeb50140eb6387a1d211ffa8f1dd7c6d25ad8d4540e480c7513d0f7034ad1617`; executable deleted |
| Historical Zig reference | SHA256 `4e021bbda7586d16f887dd04a1ded3a806ba60940179129838165d75a0c23e11`; executable deleted |

The original reference is identified by its executable hash; its `telar 0.0.0`
version string does not identify a source revision. The historical latency runner
started isolated runtimes from the same original executable for both clients;
the reference and C++ requested different production image transports.

Subsequent changes include relocating shared utilities and changing font/text/input
and benchmark tools. The old figures do not measure the current checkout. Record
the new commit, build options and executable hashes, then establish a fresh baseline
before attributing a difference to optimization.

The accepted measurements and their limits are in [PARITY.md](PARITY.md).
Terminal p50 regresses 26.6%, four splits 21.5%, four tabs 27.5%, image1K 42.3%
and image4K 131.3%. C++ wins zero of six p50 pairs in every flow. CPU and peak
RSS regress too; 4K GUI CPU is 45.90% versus 11.20%, where 100% means one core.

## What was tested

| Area | Result at the Personal checkpoint | Limit |
| --- | --- | --- |
| Packaged Preview27 | Agent reported signature/linkage checks across 1,739 files / 121 Mach-O files, schema87/88 daily launches, plugins/bars/panels and 20 normal-loop cycles passed | Historical package qualification; a new build requires its own checks |
| Graphics and attachments | Hidden Wayland resource correction, real Sway image ASan 22 checks and native/runtime regressions passed; three paired attachment paste/modal captures passed | Comparative attachment CPU includes script waits, not first-image latency |
| Blur | macOS numeric radius/cache/reset/fallback and Linux optional-protocol controls passed on both SDKs | Linux VM is correctness coverage |
| Full-client latency | Six valid alternating pairs for each of five flows, 100 inputs after 20 warmups | Fails equal-or-better performance |
| Idle | Two valid terminal pairs and three image1K pairs over native 10-second windows | External sampler boundaries are estimated |
| Sanitizers | Native shutdown checks failed; latest macOS blur run reported 345,961 bytes / 1,985 allocations | Assertions passed without an observed address/UB error; this does not make the sanitizer run pass |

Linux Qt-only controls reproduce fixture shutdown retention: client 96 bytes / one
allocation, compositor 136,407 bytes / 1,750. These are exit totals, not evidence
of ongoing growth. General framework exit-retention triage and physical suspend
are deferred. Keep direct memory/security/data-loss regressions actionable.

During integration, the frozen executable hashes, all 30 latency pairs' geometry,
readiness, marker/presentation controls and recorded image dimensions were checked
again from raw results before their removal. Recomputing the five p50 values reproduced
the report. The host is **Apple M1 Pro / 32 GiB**, confirmed by both the original
conditions receipt and `sysctl`. The report's earlier M3 label was incorrect.

### Local integration verification, 2026-11-02

Release configure and build of `telar-gui`, `gui-editor` and the selected test
executables passed with LLVM23.1.2 / Qt6.12. The 17 CTest entries below passed
with `QT_QPA_PLATFORM=offscreen` and `QT_QUICK_BACKEND=software`:

```sh
ctest --test-dir services/gui-cpp/out --output-on-failure \
  -R '^gui-(background-blur-radius|core|config|session|machines|machine-presentation|graphics|graphics-retention|graphics-recovery|attachment-capture|attachment-catalog|attachment-marker|attachment-layout|attachment-preview|plugin-packages|pick-controller|configuration-source)$'
```

The new native blur adapters, tests and probes passed clang-format checks. Actual
clangd LSP opens of `application/session.hpp`, `qt/application.hpp` and
`components/configuration.hpp` produced no diagnostics using the generated editor
contexts. This verifies compilation and selected regressions, not native rendering,
new package deployment, Linux build or performance of the integrated checkout.
No new benchmark or sanitizer run was performed during integration.

## Local optical-text optimization, 2026-11-02

With `font.thicken=true`, C++ bypassed its grouped/cached glyph path and rasterized
changed rows through Qt/CoreText into CPU images, then created replacement textures.
Two local profiles attributed about 82–83% of sampled render-thread stacks to
`TerminalItem::updatePaintNode` and 74–75% to `TextScene::addQtText`. These are
sampled stack proportions, not a distribution of elapsed frame latency.

The accepted path shapes cell runs through the existing `RowTextLayout`, caches
native optical glyph masks by face/size/style/strength, and reuses compatible
meshes and their vertex capacity. Color and projection changes reuse masks.
Vertex-capacity reuse uses Qt6.10+; older supported Qt versions retain the nodes
and masks but reallocate geometry when their glyph count changes.
Qt Quick still owns texture atlasing and submission. `OpticalText` remains the
exceptional fallback. The standard rasterizer/cache/scene policies are selected
with templates; their instances do not contain native rasterizer state. Moving
glyph placements avoids redundant mask-reference copies, and reserving the known
glyph count avoids repeated list growth. Mesh replacement swaps placement buffers
instead of copying their entries; this last change won 6/7 pairs against the
preceding cached-glyph build (4.371 to 4.173ms, identical native pixels).

CoreText rasterization, smoothing and native font discovery were brought into
`platform/macos`; Fontconfig discovery and the shared C ABI now live under
`platform/linux` and `platform/font.h`. These files no longer include or compile
the corresponding files in the Zig GUI. The C++ rasterizer borrows immutable font
bytes and caller-owned scratch pixels; its cache shares one scratch buffer across
font roles. Existing unrelated generated-data/Ghostty Zig dependencies remain.

### Paired CPU measurements

Host: Apple M3, 16 GiB, macOS26.6.2 (25G83), LLVM23.1.2, Release `-O3 -DNDEBUG`,
managed Qt6.12.0, native Cocoa/Metal. No build, lint, test suite or profiler ran
during timing. Seven alternating pairs each replayed 12 fully damaged 256×52
ASCII frames after three warmups. Telar Forma19, line height1.3, letter spacing−0.5,
optical strength250 and raster scale2 yielded a 5376×3172 capture.

Production `TerminalScene` synchronization decreased from **73.211 to 4.344ms per
repaint**, winning **7/7 pairs**; the median paired ratio was **0.0593232**.
Frame preparation and decoding are outside this interval. It includes CPU scene
work but does not measure asynchronous GPU completion, native drawable cadence,
input latency, runtime throughput, process memory or sustained application FPS.
The reference uses the unchanged historical `TextScene` and `TerminalScene` bodies
at `6152393b18f8b3e7ae1a1322eca6c8f1eb718bbd` with the same current probe/dependencies;
only the glyph-cache forward declaration/member type is adapted and recorded.
It is not an independent historical build of every GUI component.

The standard text probe uses its frozen pre-change executable, 1,000 measured
operations and 100 warmups per case. Ordered geometry/material digests matched in
every run; no other mode consistently regressed:

| Operation / glyphs | Before ns/op | After ns/op | Wins / pairs |
| --- | ---: | ---: | ---: |
| create / 32 | 1,051.4 | 912.3 | 7/7 |
| create / 128 | 3,095.4 | 2,794.1 | 7/7 |
| create / 512 | 11,353.8 | 10,426.4 | 7/7 |
| rebuild / 32 | 933.4 | 786.1 | 7/7 |
| rebuild / 128 | 3,038.0 | 2,697.5 | 7/7 |
| rebuild / 512 | 11,042.1 | 10,128.5 | 7/7 |
| repaint / 32 | 306.6 | 298.9 | 5/7 |
| repaint / 128 | 971.7 | 962.0 | 3/7 |
| repaint / 512 | 3,611.8 | 3,504.3 | 4/7 |

ARM64 disassembly confirms a warm optical glyph lookup returns after the hash
lookup without calling CoreText, copying masks or creating textures. Mesh capacity
growth is conditional. An intermediate variant outlined additional list/mesh work
and consistently regressed standard construction/rebuild by several percent;
it was rejected. Earlier unconditional mesh retention and copy-based construction
also regressed standard text. The final policy separation, moves and reservation
above passed the paired checks; no code-placement exception was used.

### Visual and functional verification

The independent visual reference executed original Zig `RowRuns`, `ShapedRun`,
`GlyphAtlas` and its CoreText adapter on the same cells and font. Its 13,209 ordered
quads were composited with nearest alpha sampling over black. Default1024 and
maximum2048 atlas sizes produced identical RGB output. The final native Qt capture
differs by **zero pixels / zero channel values** from that reference. Its RGB SHA256
is `b23e05bac53b1c1f95040f023741bab59b4eff5f454983b389f10caae81b4fce`;
font SHA256 is `f482d6bf04e135c8a0695f48f93a7b05862666862a4a1bdc5bc7f5bb48cc1271`.
The preceding C++ renderer differed at 7,600 grave-accent pixels. Therefore this
case uses the independent Zig reference instead of accepting that existing defect.
It does not establish pixel parity for every font or terminal configuration.

All four focused CTest entries passed: `gui-optical-text`, `gui-row-text`,
`gui-chrome-text`, `gui-font-resolver`. The optical test covers 432 size/strength/style
cases and checks native wrapper masks byte-for-byte at identical atlas coordinates.
The row-text oracle matched 7,494 original-Zig cases across three bundled faces,
including all printable ASCII and grave accents. Native Metal regular/emphasized
mask/placement tests passed, as did `terminalInputAndRendering` and
`terminalFramesWaitForSceneSynchronization` against the C++ runtime. Clang-tidy
passed all nine touched translation units checked in this pass. The native C and
C++ rasterizer adapters also compiled for x86-64; the Fontconfig adapter passed
C17 syntax/warning checks against Fontconfig headers on this host. No Linux runtime,
Rosetta execution or new sanitizer qualification was performed.

An initial text-only surrogate did not reproduce production `TerminalScene`
grouping and was discarded as a visual/performance qualification. Attempts to use
the historical full-client latency harness failed viewport/marker readiness; those
runs do not support an application-latency or FPS claim. Use the complete-stack
flow contract for that next measurement.

### Reproduction and identities

Build `gui-terminal-scene-probe` and `gui-text-scene-probe` in the configured Release
directory. `tools/build_terminal_scene_reference.py --build-dir BUILD --revision REV
--output-dir BASELINE` builds historical scene bodies with the current workload and
records original/adapted source hashes and commands. Then run:

```sh
python3 services/gui-cpp/tools/compare_terminal_scene.py \
  BASELINE/gui-terminal-scene-probe-reference BUILD/gui-terminal-scene-probe \
  RESULTS --font 'Telar Forma' --scale 2 --iterations 12 --warmup 3 --pairs 7 \
  --reference-image INDEPENDENT_REFERENCE.png
python3 services/gui-cpp/tools/compare_text_scene.py \
  FROZEN/gui-text-scene-probe BUILD/gui-text-scene-probe \
  --output-dir STANDARD_RESULTS --pairs 7 --iterations 1000 --warmup 100
```

Use fresh output directories outside the repository. Without `--reference-image`,
the terminal comparison requires exact baseline/candidate pixels. The supplied
reference must match the workload/font/viewport; another font is a different case.
The Zig reference above is a historical validation, not a new production dependency.

For changes to retained Qt nodes, add `--render-each-frame` to the terminal
comparison. The default probe applies every update before its first rendered
frame; it cannot expose the renderer's removal/reinsertion work between frames.
The new mode requests each update after the preceding frame swap. Its timer
still covers scene synchronization, including immediate Qt dirty notifications,
not subsequent rendering or presentation. `--floating-window` uses a Qt tool
window to avoid tiling of the probe on window managers that support that policy.
Reject image comparisons with different dimensions. The comparison now checks
host load before/after every variant and invalidates the whole series on failure.

Measured executable SHA256 values:

| Executable | SHA256 |
| --- | --- |
| Historical terminal scene probe | `0aac5f88c239196695325fd5ff214b1d4386932029f21bbb13afea733dc3cbda` |
| Final terminal scene probe | `2e20dbd52c29cde78b7239a3e7ba7e426c297845d03c2f7ab6db931710490d78` |
| Frozen standard text probe | `3a3d0192de4f18de71ab88aabaaacb33ffff8af362518440f75763619b1a40eb` |
| Final standard text probe | `b3ff061b4a55396e468c567d5f9cc87882e3ab3b4ddafaf7ea9bb7142b5ca301` |
| Final GUI | `cb77d9c79b65cedf60e41ca01cb26e6e904183daee5772e0e5bdd74191e9179d` |

Raw captures, manifests, assembly and pair logs stayed in a private temporary
directory, outside version control. The measurements describe the working-tree
build with the hashes above, not the unchanged HEAD executable or Preview27.

### Font request equivalence

For changes to `TerminalItem::requestRowFonts`, freeze the reference and candidate
`terminal_item.cpp/.hpp` files in separate directories, then run:

```sh
python3 services/gui-cpp/tools/check_terminal_font_requests.py \
  --build-dir BUILD --reference REFERENCE_QT --candidate CANDIDATE_QT \
  --output-dir FRESH_RESULTS
```

The configured GUI build must have its common libraries and the
`gui-terminal-scene-probe` target built. The tool transplants the actual request
method and collection-installation block into a small facade, using the build's
real `CellValue`, `Face`, `FontCoverage` and QString normalization. The catalog
records fallback request roles and bytes, including repeated missing requests.
Its corpus contains 889,336 cells across five bundled faces, collection changes,
all one/two-byte strings, Unicode boundaries, malformed UTF-8, continuation cells
and seeded flags. Exact output equality is required; input, sources, commands,
libraries, executable hashes and output streams are retained.

Both variants share the configured common libraries, so this oracle only isolates
the extracted TerminalItem code. It models catalog storage and excludes native
font discovery, asynchronous completion and rendering. It does not measure
performance. A deliberately omitted cache reset must fail before relying on the
oracle for a coverage cache; native rendering and configuration reload checks
remain separate requirements.

## Measurement contract and invalid runs

The endpoint starts at native `NSView.keyDown` invocation and ends at positive
`CAMetalDrawable.presentedTime` for the drawable containing verified marker pixels.
It excludes hardware keyboard latency and physical scanout. GPU completion and
protocol acknowledgements are different endpoints. Initial readiness must qualify
before input; focus, VSync, matching viewport/grid/layout and pane geometry are gates.

Conditions: native macOS26.6.2 on AC, Cocoa/Metal, Qt6.12, LLVM23.1.2,
1600×1000 render pixels, DPR2, bundled JetBrains Mono15, `shade` theme, sidebar
visible, cursor blink off, zero window padding and opaque background. The display
reports 120 fps maximum. Zig records SDK15.4; packaged C++ records SDK26.5.
The currently available SDK is not evidence of how a frozen binary was linked.

Graphics inputs use the same Kitty shared-memory producer. The marker comes from
image pixels, with no text marker to acknowledge an image prematurely. Fixture
dimensions must be passed explicitly through argv and verified from `graphics.json`.

| Excluded observation | Why it cannot support an accepted latency comparison |
| --- | --- |
| 24 earlier rows labelled 4K | Two collections actually used the 1024² default; parent `BENCH_*` environment values were filtered or lost across runtime spawning |
| 12 fixed-rate text-load rows | Offered background output missed the unchanged 5% rate tolerance |
| One idle Zig presentation failure and its C++ partner | The Zig row failed; a valid unpaired partner is not a pair |
| Negative controls | Initial zero timestamp fails4 before input; missing record / VSync / dropped controls fail19/20/21 |
| Profiled runs and early one-pair experiments | Diagnostic observations, outside the final uninstrumented collection |

An outer driver can exit0 while retaining rejected rows. Inspect each row's
`error`, native failure code and pair compatibility. Use medians of per-run quantiles,
not pooled samples. GUI CPU uses native getrusage after warmup; peak RSS includes
startup, viewport negotiation and probe buffers. The separate 100ms resource sampler
mislabelled Mach ticks as nanoseconds. Its corrected analysis used timebase125/3,
with a 200ms getrusage control agreeing within 0.01%. For new measurements, obtain
the host's actual timebase and validate units again. GUI native counters were independent.
Keep GUI/runtime measurements separate and avoid summing shared RSS.

## Experiments already tried

| Experiment | Observed presentation p50 | Decision |
| --- | --- | --- |
| `QSG_RENDER_LOOP=basic` versus `threaded` | 29.80 versus 28.95ms, one pair ×30 inputs | No accepted gain; split-load rows invalid on offered rate |
| `QT_QPA_UPDATE_IDLE_TIME=0` versus default | 29.51 versus 28.96ms, one pair ×30 inputs | No accepted gain; split-load rows invalid on offered rate |
| Read-only 4K profiles | Socket/chunk copies, `GraphicsStore::Image::append`, RGBA conversion/premultiplication and Metal upload copies appear in sampled stacks | Leads for isolation, not attribution of the entire regression |

At the Preview27 checkpoint, no production optimization was accepted. The two environment experiments are
small preliminary observations, insufficient to prove a general configuration rule.
Their earlier GPU-only quantiles are not comparable to the final presented endpoint.

The former 4K profiles sampled GUI and runtime separately for each implementation.
The reports were deleted; the observed paths above remain leads to profile again.
Relevant source paths are `application/session.hpp`
for `ConfigureGraphics{false}`, `qt/runtime_connection.cpp`, `transport/frame_stream.hpp`,
`graphics/store.hpp`, `qt/window_images.cpp` and `qt/image_resource.cpp`.
The C++ upload path converts to premultiplied RGBA and copies into texture staging;
inline versus shared-memory transport is another measured-path difference.
Whether these explain most of the latency or extra memory remains a hypothesis.

## Prepare a new measurement

Dispatch from the current source revision, using a new branch and checkout on
Personal. Only commits travel between machines: include the intended local work
before dispatch and record the exact source SHA. The old task branch and Personal's
existing main checkout are historical state, not the new task's starting revision.
See [the Personal handoff](../../docs/gui-cpp-personal-handoff.md).

Configure compiler/SDK, Qt, Ghostty and other pinned dependencies from declared
inputs using [README.md](README.md). Use new build/output directories. Build and
identify both the current C++ Release and a compatible Zig reference; record their
source revisions, hashes, SDKs and runtime choice. Preserve the installed app and
user runtime; measurements use isolated runtimes and owned temporary sessions.

The source tools include `tools/gui_tui_latency.py` with `--mode telar`,
`--cpp-gui`, `--config`, `--endpoint presented` and `--viewport` options, plus the
fixture/oracle tests beside it. Read their current help and implementation before
use. Qualify readiness and negative controls against the measurement contract above.
Implement missing reusable workload/runner support in source, rather than depending
on deleted ignored scripts. In particular, pass graphics dimensions through argv
and verify receipts; retain marker-only image presentation and offered-rate checks.

Run from a native graphical login with matched configuration/fonts/geometry. Keep
builds, tests, lints and profilers separate from timing. Use fresh output names,
alternate clients and validate each pair before aggregation. Create a new Linux
environment if needed; the previous VM and SSH helper are gone. Offscreen/software
tests and VM results do not establish native frame latency.

## Continue in this order

1. Freeze the current build and compare it with the freshly identified Zig reference.
   Finish with matching hashes/options, qualified controls and six valid pairs per
   target flow. Record failures and missing prerequisites as such.
2. Profile the largest confirmed regression separately from timing. Isolate transport
   copies, image conversion/upload and terminal input-to-frame scheduling. Finish
   with a measured cost and functional oracle for the proposed change.
3. Make one bounded change using reusable components and existing allocator/DI patterns.
   Keep image budgets, generations, cancellation, alpha/color behavior, hidden-surface
   recovery and presentation controls. Run the affected source tests and inspect
   generated assembly where it explains the measured cost.
4. Compare the variant with the fresh C++ baseline in alternated pairs, then with Zig.
   Follow [perf-pass](../../.agents/skills/perf-pass/SKILL.md) acceptance: at least
   5/6 benchmark wins with no consistent regression in other flows; renderer-specific
   seven-pair cases use 6/7. Recheck the final build and idle CPU/RSS. Only report
   equal-or-better parity after the full-client measurements support it.

Keep concise findings and decisions here or in PARITY. Generated results, profiles,
screenshots and frozen binaries belong in ignored `out*/` or private storage.

## Native history query observer

`tools/gui_history_latency.py` launches an isolated, explicitly selected runtime
and GUI, then alternates two history queries through native text input. It requires
macOS with the Metal4 SDK, clang and Pillow. The companion Objective-C probe uses
the ordinary Metal or Metal4 render submission to copy a bounded result region;
it accepts only matching pixels on that drawable with a positive presentation
timestamp. It checks focus, geometry, VSync, executable identities and host load,
and cleans up its owned processes. `--help` lists the inputs.

Supply a SQLite history fixture, a configuration shared by both stacks, and a case
JSON such as this. Coordinates are physical drawable pixels; viewport dimensions
are native points. Template paths are relative to the case file unless absolute.

```json
{
  "viewport": [1600, 1000],
  "drawable": [3200, 2000],
  "region": [320, 1592, 512, 48],
  "queries": [
    {"text": "gb", "template": "selected-build.bgra"},
    {"text": "GST", "template": "selected-status.bgra"}
  ]
}
```

Each template is tightly packed BGRA8 from an independently verified native result
capture. The region must identify different returned content and exclude the query
field. Templates are not an independent ranking oracle and separate renderer
templates do not prove visual parity. Validate raw pixels with `--observe-only`
before timing; use the stale/missing/zero `--negative` controls to qualify rejection.
The `callback` control withholds one drawable completion while allowing a later
verified result, and checks that the driver still refuses to advance. Positive
trials require all submitted drawables to finish both pixel and presentation
callbacks. ROI rows are aligned for Metal transfer and compared without padding.

```sh
python3 tools/gui_history_latency.py out-history-query \
  --kind cpp --runtime /path/to/stage/telar --gui /path/to/stage/telar-gui \
  --qt-prefix /path/to/qt/install --config /path/to/shared.lua \
  --fixture /path/to/history.db --case /path/to/case.json --samples 60
```

For Zig, pass `--kind zig` and the independent Zig executable as both `--runtime`
and `--gui`. The native endpoint begins immediately before replacing selected
query text, so application debounce is included. Selection preparation and the
50 ms inter-query callback drain are excluded from individual latency samples but
included in GUI/runtime resource intervals. These are warm query replacements,
not cold-query, sustained typing or native120 acceptance. Resource snapshots are
separate for GUI and runtime; lifetime footprint maxima are not interval peaks.
Hook `elapsed_ns` fields measure wall time, not process CPU, and submission GPU
time includes rendering as well as readback. Observer perturbation still needs
qualification before using small timing differences to accept an optimization.
