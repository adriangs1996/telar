# Complete-stack performance progress

This is the current work log for [F01–F16](cpp-performance-flows.md), starting
from `6152393b18f8b3e7ae1a1322eca6c8f1eb718bbd` on 2026-11-02. The persistent
objective is active and unbounded. No flow has complete-stack performance
acceptance yet; no production performance optimization has been accepted.

## Fresh environment

Personal reports Apple M1 Pro, MacBookPro18,3, 32 GiB, ten CPU cores, 128-byte
cache lines, macOS 26.6.2 / 25G83 and AC power. The native probe identifies
display 1 and a maximum of 120 Hz. Active sustained presentation cadence is
still unqualified; the maximum is not a measurement of actual refresh.
The new `gui-display-probe` reports Qt 6.12.0/Cocoa, DPR 2 and 120 Hz on the
built-in screen. The suspected Qt-reports-60-Hz cap is not present in this run.

All generated artifacts are under ignored `out-perf/` or private
`/tmp/telar-perf-*` directories. No installed application or user configuration
is replaced. `out-perf/baseline/conditions.json` records machine, source,
dependency, executable hash, dynamic linkage and Mach-O SDK evidence.

- Fresh C++ runtime and GUI Release builds use LLVM 23.1.4, CMake 4.4.5,
  SDK 26.5 and the installed Qt packages recorded by CMake. Runtime and GUI
  are copied together to `out-perf/baseline/stage-cpp/bin`, with the C++ runtime
  named `telar` for GUI discovery and plugin helpers.
- Ghostty `df1c99c8…` plus the checked-in state patch was freshly compiled
  with Zig 0.17 into `out-perf/dependencies/ghostty`.
- The reference source requires Zig 0.16. Zig 0.17 rejects its build APIs.
  Official Zig 0.16.0 was downloaded into `out-perf/toolchains` and checked
  against the SHA-256 in the official download index.
- Native automatic SDK selection failed in libc++ and translated Mach
  structures. The reference uses the existing `sdk-libc.sh`, CLT SDK 26.5,
  `-Dtarget=aarch64-macos.26.0 -Dcpu=apple_m1` and `--libc`. The clipboard
  import now names the four CoreFoundation headers actually used, avoiding
  unrelated Mach structures in the umbrella header. This is a build repair,
  not a performance optimization. The resulting Zig Release build passes.
- The first C++ runtime build accidentally found nghttp2 in the general
  Homebrew include directory, which shadowed OpenSSL 3 headers with OpenSSL 4.
  Explicit `NGHTTP2_ROOT/INCLUDE_DIR/LIBRARY` pointing to `libnghttp2` corrected
  the build. The OpenSSL 3 ownership assertion remains intact.

## Measurement controls

`gui_tui_latency.py` now requires `--cpp-runtime` for C++ GUI runs. It starts
and stops that runtime, checks the staged GUI helper's hash, and records actual
GUI process and connected socket-peer executable identities. A selected Zig
runtime remains explicitly labelled a same-runtime diagnostic. Runtime readiness
is bounded; background launch completion does not imply socket readiness.
The aggregate uses medians of run quantiles, rather than pooled samples.

Focused Python identity/report tests and the native readiness join pass.
The latter rejects missing/zero/stale presentation evidence. Full-client
negative controls and helper-process resource accounting remain pending.

Qualification 01 exposed the asynchronous runtime-start race. Qualification 02
verified both C++ executable identities, but failed viewport negotiation before
input because the window manager controlled its size. Both owned runtimes and
children were cleaned up. Qualification 03 uses the existing `--float-windows`
control, which affects only probe windows. It reaches setup readiness, then
times out on the first input despite the fixture receiving `x`. A second pair
qualification repeats that C++ failure while Zig completes. C++ qualification
04 with capture and a diagnostic run with GPU pixel logging both pass; the
intermittent failure remains unresolved. These are setup/diagnostic attempts,
not accepted paired performance measurements.

Further reproduction isolates the failure after rendering: the GPU readback
has the correct green pixel, but the corresponding native presented callback
returns zero. `cpp-readback-02` passed five starts and failed the sixth;
`cpp-readback-03` passed six; `cpp-readback-04` passed two and failed the third.
`cpp-readback-05` confirms zero timestamps with native occlusion-visible true,
window frame `[910,321,800,500]`, display 1 and `presentsWithTransaction=false`.
The cause remains open; GPU completion is not substituted for presentation.
Readback diagnostics are opt-in and labelled in new reports.

`f03-capture-baseline-01` starts a provisional six-pair comparison with identical
capture setup, 20 warmups and 100 measured inputs per run, 1600×1000 pixels,
DPR 2 and an 82×21 grid. It does not close the failure without capture or the
remaining native negative controls. No builds/tests/profiles overlap this run.
The collection stopped on the first Zig run with no completed inputs.
`zig-readback-01` reproduces the same correct-green-pixel/zero-presented-time
failure on Zig, so this is not established as a C++ regression. Apple documents
[zero presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
as unpresented/dropped; these runs remain invalid. The next qualification
separates warm typing (`--idle-seconds 0`) from input following two seconds of
idle, retaining the same positive-presentation gate for both.
The first warm qualification passes in both complete stacks, with equal grid,
viewport and marker coordinates. A six-pair, 100-input warm baseline follows
under `f03-warm-baseline-01`; full F03 acceptance remains open.

The attempted C++ GUI + Zig runtime diagnostic cannot connect: current C++
uses schema `cqp00001`, while Zig uses `886b480d`. Shared component probes also
need schema-appropriate drivers before cross-runtime timing. Do not bypass
the handshake or decode the new input-mode fields with the old frame layout.

## Coverage and next experiments

Every row below remains open. Existing component/functional probes do not prove
the visible endpoint or a full-flow win. Six valid alternating full-client pairs
and the existing seven-pair component contracts remain mandatory.

| Flow | Reusable support | Missing acceptance work |
| --- | --- | --- |
| F01 | Isolated launch and initial marker readiness | Launch timing, restore, surviving children |
| F02 | Native GUI idle getrusage | Separate runtime/wakeup/settled memory, hidden/disconnected |
| F03 | Native keyDown to verified presented marker | Full-stack pairs; Unicode/combining/cursor/paste variants |
| F04 | Fixed-rate fixture, ASCII/ANSI DSR and runtime probes | Unicode, final-content oracle, concurrent input and resource evidence |
| F05 | TUI/terminal fixtures | Deterministic full TUI trace and presentation cadence |
| F06 | Native wheel injection, terminal scroll probes | Continuous scrollback/selection/live-return content and cadence |
| F07 | Four splits and fixed-rate background load | All producers active, fairness and cadence |
| F08 | Four tabs and background output | Repeated tab/workspace switching to verified target content |
| F09 | Native resize and blur controls | Continuous window/divider motion, clipping, matched backgrounds |
| F10 | Kitty producer and image marker tooling | Integrated 1K/4K receipts, alpha/generations, image latency plus UI cadence |
| F11 | Private clipboard/shelf/modal captures | Independent runtimes, actual image endpoint, bounded multi-attachment cases |
| F12 | History/query probes and GUI captures | Independent runtimes, cold/warm queries to presented results |
| F13 | Agent/report/sidebar fixtures | Report-to-presentation under streaming load, service overhead |
| F14 | Configuration/plugin/path/suggestion probes | Complete configured interactions, worker cost and cadence |
| F15 | Local reconnect and SSH configuration fixtures | Owned real SSH, controlled backpressure, continuity and presentation |
| F16 | Proxy, CONNECT, HTTP/1, HTTP/2 and capture oracles | Equal-feature service load concurrent with GUI, resources/queue bounds |

First profiling candidates are the refresh value sent by each GUI, GUI pacing
phase versus VSync, and whole-viewport repaint during subcell resizing. Further
leads are repeated font coverage lookup, per-cell row-revision division, runtime
scrollback projection and history-query scratch/statement reuse. Each needs a
fresh profile, equivalence oracle, disassembly and paired acceptance before it
can be retained as an optimization. Historical rejected batching, relay-buffer,
prefault, render-loop and update-idle variants remain documented in the existing
GUI/runtime performance reports.
