# C++ GUI optimization handoff

The remaining scoped task is the measured performance regression against the Zig
GUI. Graphics/attachments and native blur have shipped in Preview27. Preserve
functional and visual behavior, explicit allocators, compile-time dependency
selection and the application/platform boundary. The wider feature backlog and
runtime/CLI/plugin-worker migration are separate work.

## Source and measured candidate

| Checkpoint | Identity and state |
| --- | --- |
| Last production change measured | `a1ea73a89465d1144921e6a924436085601c5537`, native blur and Preview27 |
| Final Personal branch | `089a07dcd6cd719f80c56625652afacb87060635`, benchmark report after artifact cleanup |
| Integration into this branch | `36adb7d4f7be59c79323396db4fd8ac54142f48d` |
| C++ baseline | Exact deployed Preview27, SHA256 `eeb50140eb6387a1d211ffa8f1dd7c6d25ad8d4540e480c7513d0f7034ad1617` |
| Zig reference | Frozen `bin/original-telar`, SHA256 `4e021bbda7586d16f887dd04a1ded3a806ba60940179129838165d75a0c23e11` |

The original reference is identified by its executable hash; its `telar 0.0.0`
version string does not identify a source revision. The C++ baseline's bundled
runtime/helpers are preserved alongside it. The latency runner starts isolated
runtimes from `bin/original-telar` for both clients; the reference and C++ request
different production image transports.

Integration preserved 127 modified tracked files and 43 untracked files. These
include moving shared desktop utilities into `dlls/telar-client`, `qt` and
`platform`, plus font/text/input and benchmark-tool changes. They are outside the
frozen measurement. Record the current commit, diff, build options and binary hashes,
then measure a fresh baseline before attributing a change to optimization.

The accepted measurements and their limits are in [PARITY.md](PARITY.md).
Terminal p50 regresses 26.6%, four splits 21.5%, four tabs 27.5%, image1K 42.3%
and image4K 131.3%. C++ wins zero of six p50 pairs in every flow. CPU and peak
RSS regress too; 4K GUI CPU is 45.90% versus 11.20%, where 100% means one core.

## What was tested

| Area | Result at the Personal checkpoint | Limit |
| --- | --- | --- |
| Packaged Preview27 | Agent reports signature/linkage checks across 1,739 files / 121 Mach-O files, schema87/88 daily launches, plugins/bars/panels and 20 normal-loop cycles passed | The frozen package was qualified; this branch's later work is a different build |
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
again from the retained raw results. Recomputing the five p50 values reproduced
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
mislabelled Mach ticks as nanoseconds. Apply `resource-counter-unit-correction.json`
with timebase125/3 for those counters; raw samples were retained unchanged. Its
200ms getrusage control agrees within 0.01%. GUI native counters are independent.
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

The 4K profiles are in `profiles-actual-four-k-1`, with separate GUI/runtime reports
for each implementation. Relevant source paths are `application/session.hpp`
for `ConfigureGraphics{false}`, `qt/runtime_connection.cpp`, `transport/frame_stream.hpp`,
`graphics/store.hpp`, `qt/window_images.cpp` and `qt/image_resource.cpp`.
The C++ upload path converts to premultiplied RGBA and copies into texture staging;
inline versus shared-memory transport is another measured-path difference.
Whether these explain most of the latency or extra memory remains a hypothesis.

## Reproduce from the retained Personal inputs

Use the task worktree and machine in [the Personal handoff](../../docs/gui-cpp-personal-handoff.md).
Set `benchmark_dir` there, relative to that worktree:

```sh
benchmark_dir="$PWD/services/gui-cpp/out-dependencies/adoption-benchmark-1"
shasum -a 256 "$benchmark_dir/bin/original-telar" \
  "$benchmark_dir/candidate/Telar C++ Preview 27.app/Contents/MacOS/telar-gui"
```

These inputs exist on Personal, not in a fresh clone. `frozen-inputs.json` lists
their hashes; `candidate-freeze.json` records the deployed copy and SDK.
`valid-pair-summary.json` and `summarize_valid_pairs.py` describe the final aggregation.
Use `headline-final-1` for terminal/splits/tabs/1K and **`graphics-four-k-final-2`**
for actual3840×2160. Resource correction, idle and attachment results are adjacent.

The retained local runners preserve the final oracle and adaptations. From a native
graphical login, without concurrent builds, tests, profilers or lints, use fresh names:

```sh
python3 "$benchmark_dir/run_comparison_ready.py" \
  --name optimization-reference-text-1 --rounds 6 --samples 100 \
  --cases single splits tabs graphics-1k
python3 "$benchmark_dir/run_comparison_graphics_argv.py" \
  --name optimization-reference-4k-1 --rounds 6 --samples 100 --cases graphics-4k
```

These commands compare the old frozen binaries. A new C++ build requires a separate
runner/input manifest selecting that build; keep the reference and Preview27 intact.
The retained drivers select their candidate path internally. Preserve their readiness,
geometry, dimension, negative and rate checks when adapting them. Use new output names
and validate each pair before aggregation. `run_comparison_ready_idle.py --idle`
provides idle collection; its other arguments follow the same pattern.

Current source tools include `tools/gui_tui_latency.py` with `--mode telar`,
`--cpp-gui`, `--config`, `--endpoint presented` and `--viewport` options, plus the
fixture/oracle tests beside it. They have local changes since the frozen harness.
Qualify their controls before using them as a replacement for the retained drivers.
Linux mirrors and offscreen/software tests do not establish native frame latency.

## Continue in this order

1. Freeze the integrated build and reproduce its gap against both Preview27 and Zig.
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
