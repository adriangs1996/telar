# C++ GUI optimization handoff

The new complete-stack performance task is defined in
[cpp-performance-flows.md](../../docs/cpp-performance-flows.md). It covers both
runtimes and GUIs, with native 120 Hz smoothness where supported. The historical
GUI-only findings below are inputs to that task, not acceptance of the new matrix.

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

No production optimization was accepted. The two environment experiments are
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
