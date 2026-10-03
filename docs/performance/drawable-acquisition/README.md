# Drawable acquisition on macOS

Fable's work is imported and its remote worktree/session removed. Three new
acquisition experiments were rejected; the production renderer remains identical
to the imported baseline. The retained change is a bounded diagnostic that
separates thread CPU from drawable wait time, with its regression test and raw
evidence. A long `nextDrawable` call is not evidence of a CPU or cache bottleneck.

## Imported work and cleanup

Fable's branch `perf-window-render-worker`, ending at `b0408f82`, is an ancestor
of merge `c8fa3113` in `perf-access-clusters-2`. The merge preserves the preceding
[access-cluster pass](../access-clusters-2/README.md), Fable's macOS libproc build
fixes, native-test diagnostics, and the entire
[render-worker report](../window-render-worker/README.md). Fable had reverted the
worker itself; its implementation remains an experimental patch in that report.

After verifying the import, the clean remote worktree and its agent session were
removed through telar on Personal. [The subsequent worktree listing](personal-worktrees.json)
is empty. The remote branch was preserved because it is not merged into Personal's
`main`; neither that branch's history nor the installed application was replaced.

## Environment and endpoints

Measured on 2026-10-03, Apple M3, macOS 26.6.2, Zig 0.16.0, ReleaseFast with
`diagnostics`, `echo-trace` and `echo-trace-cpu`. The native window used the
external DELL P3225QE at 100 Hz, a fixed 1900 × 1100 pixel viewport and backing
scale 1. [Binary and patch hashes](experiment.json) identify the immutable builds.
Fable measured a different machine and 120 Hz display; its timing values are not
used as this pass's baseline.

The principal comparisons reuse Fable's `pair_load.py` and telar's existing
`gui_tui_latency.py`: seven adjacent A/B pairs, alternating order, 100 measured
inputs after 20 warmups per case. `single` types into one idle pane;
`splits-load` types into one pane while three others flood output. Each response
requires the expected marker pixel in the completed GPU submission. This measures
native key dispatch to verified GPU completion, not physical presentation or
scanout. In `gui_tui_latency.m`, `began` is assigned immediately before the
synthetic `keyDown` call on the main thread. Time already spent waiting to deliver
an OS event to that thread is therefore excluded. These results cannot establish
that a worker has no benefit for event-queue responsiveness; that would require
an independently timestamped enqueue-to-pixel benchmark. The probe makes the drawable readable, unlike production's
`framebufferOnly=true`. No compilation, tests or stack sampling ran alongside
these paired latency measurements.

Percent changes below are medians of the seven paired ratios, not ratios of the
two displayed medians. The acceptance rule requires at least 6/7 target wins and
no consistently regressing control. Raw per-run comparison files, including
sample arrays, viewport checks, warmups and executable hashes, are compressed in
[samples](samples).

## Why elapsed time dominates

The bounded `gui_slot_probe` now also records `CLOCK_THREAD_CPUTIME_ID` around
`nextDrawable`, separately from the existing wall clock. Its analyzer only accepts
CPU samples whose complete acquisition interval lies inside the measurement
window. Old traces remain readable and have no CPU samples. A synthetic control
checks an 8 ms elapsed interval with 0.125 ms CPU, interval clipping and legacy
traces. The final hook limits acquisition tracing to the main thread; internal
Core Animation acquisition on other threads is outside that metric.

An initial full-screen text diagnostic, one pane updated at 120 Hz on the 100 Hz
display, recorded 1,018 complete acquisitions:

| Acquisition metric | p50 ms | p95 ms | p99 ms | Total ms |
| --- | ---: | ---: | ---: | ---: |
| Elapsed | 0.0472 | 6.3338 | 14.2826 | 857.4476 |
| Calling-thread CPU | 0.0435 | 0.0820 | 0.1051 | 43.8679 |

CPU was 5.12% of aggregate acquisition elapsed time. The complementary duration
is off-CPU time, not a count of cache misses. The initial probe source and raw
trace are archived as `samples/slot-probe-initial.m` and `A-slot-*`.
A separate, untimed stack profile reaches
`CAMetalLayerPrivateNextDrawableLocked` → `_dispatch_semaphore_wait_slow` →
`semaphore_timedwait_trap`. Its profile and trace are archived as `A-profile-*`;
profiler-affected timings are not mixed into the paired tables.

This matches Apple's documented [nextDrawable behavior](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable%28%29):
it can wait for an available drawable. The documentation of
[CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer)
also makes drawable lifetime relevant to reuse. Neither source establishes that
changing the layout of Telar's fields would remove this wait.

## B: drawables supplied by CAMetalDisplayLink

[Patch](metal-display-link.patch). Replace `CADisplayLink` and immediate
`nextDrawable` with a `CAMetalDisplayLink` delegate, preferred frame latency 1.
The callback checks visibility, the frame budget, renderer ownership and drawable
size before preparing. Preparation and model access remain on the main thread;
there is still one GPU submission in flight. Idle and occluded windows pause the
link. Closing invalidates it before joining GPU work. No worker queue or borrowed
model pointers cross threads.

This revisits the scheduling strategy rejected in the earlier
[Metal 4 migration](../native-terminal/metal4.md), now with current pacing,
100 Hz and a paired flood workload. It is not a previously untested API in Telar.
Apple documents the drawable delivery and scheduling controls on
[CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink).

| Case | Metric | A median ms | B median ms | Paired change | B wins |
| --- | --- | ---: | ---: | ---: | ---: |
| single | p50 | 4.707 | 9.611 | +113.6% | 0/7 |
| single | p95 | 9.872 | 17.945 | +81.8% | 0/7 |
| single | p99 | 12.557 | 19.245 | +72.6% | 0/7 |
| splits-load | p50 | 8.809 | 9.108 | +2.5% | 2/7 |
| splits-load | p95 | 17.121 | 17.019 | -21.9% | 5/7 |
| splits-load | p99 | 21.257 | 19.298 | -30.3% | 6/7 |

**Rejected.** The loaded p99 gain comes with a consistent idle regression.
This changes scheduling and does not qualify for an assembly-placement exception.
The immediate path after idle is lost. A separate full-text diagnostic observed
92.61 active FPS for A and 71.58 for B, but those single sequential runs are not a
paired throughput result and are not needed for the rejection.

B records no application `nextDrawable` calls. That does not mean drawable
acquisition became free: Core Animation supplies the drawable. Pixel verification
remains valid; the old synchronous draw-attempt phase decomposition cannot be
used to attribute B's complete acquisition latency.

## C: drain frame temporaries earlier

[Patch](frame-autorelease-pool.patch). Keep the original scheduler and put only
acquisition, preparation and submission inside a local `@autoreleasepool`.
`active_drawable` and all GPU resource owners remain strong until GPU completion,
so the experiment does not release resources still in use or add threads.

| Case | Metric | A median ms | C median ms | Paired change | C wins |
| --- | --- | ---: | ---: | ---: | ---: |
| single | p50 | 2.774 | 2.738 | +1.3% | 2/7 |
| single | p95 | 6.683 | 6.767 | +3.5% | 3/7 |
| single | p99 | 7.577 | 7.629 | +0.4% | 3/7 |
| splits-load | p50 | 6.123 | 6.210 | +1.2% | 3/7 |
| splits-load | p95 | 14.906 | 12.718 | -5.4% | 6/7 |
| splits-load | p99 | 21.043 | 19.831 | +3.5% | 3/7 |

A second, independent seven-pair experiment used the bounded phase trace with
full text output at 120 Hz on the same 100 Hz display. Both builds reported a
three-surface pool. Acquisitions showed:

| Phase | Metric | A median ms | C median ms | Paired change | C wins |
| --- | --- | ---: | ---: | ---: | ---: |
| elapsed | p50 | 0.0578 | 0.0575 | +4.53% | 2/7 |
| elapsed | p95 | 14.7196 | 15.7814 | +18.22% | 1/7 |
| elapsed | p99 | 19.8667 | 19.8794 | +0.01% | 3/7 |
| CPU | p50 | 0.0479 | 0.0485 | +2.03% | 2/7 |
| CPU | p95 | 0.0807 | 0.0814 | -1.85% | 4/7 |
| CPU | p99 | 0.1046 | 0.1051 | +1.14% | 3/7 |

**Rejected.** The loaded input p95 signal does not establish a general gain, and
the direct acquisition p95 regresses in 6/7 pairs on full output. CPU changes are
mixed. The cause of that elapsed-time regression is not established; these data
do not justify attributing it to cache behavior or a specific driver mechanism. The reused
pairing script labels the candidate `B` even in the C and D series; manifests
identify the actual binary.

## D: two surfaces instead of three

[Patch](double-buffer.patch). Set `maximumDrawableCount` to two while preserving
VSync, the immediate acquisition path, pacing and single-submission ownership.
The hypothesis is that reduced presentation depth might shorten latency; the
counter-risk is more time waiting for a free surface. The native probe records
the actual configured drawable pool capacity rather than assuming the default.

| Case | Metric | A median ms | D median ms | Paired change | D wins |
| --- | --- | ---: | ---: | ---: | ---: |
| single | p50 | 4.855 | 5.185 | +6.2% | 2/7 |
| single | p95 | 10.235 | 12.970 | +17.1% | 3/7 |
| single | p99 | 15.760 | 16.397 | +16.1% | 3/7 |
| splits-load | p50 | 8.794 | 16.145 | +80.3% | 0/7 |
| splits-load | p95 | 20.732 | 30.929 | +50.6% | 0/7 |
| splits-load | p99 | 26.283 | 31.743 | +25.9% | 0/7 |

**Rejected.** All three loaded percentiles lose every pair. Reducing drawable
capacity is not equivalent to removing a queued frame from Telar: it already has
only one GPU submission in flight, while Core Animation owns presentation.
A separate diagnostic confirms the configured capacity was two and the display
100 Hz (`samples/D-slot-*`); its timings are not another paired comparison.

## Assembly and limits of a data-layout change

The [baseline listing](assembly/drawIfReady-A-symbolic.s) has 186 ARM64
instructions, including all guard and standalone-host branches. The call at
`0x100049c68` is the Objective-C dispatch of `nextDrawable`; the next operations
retain the returned object, test for nil and eventually call `drawWithDrawable:`.
There is no array traversal or per-cell load loop in this caller. The floating
point divide computes standalone fallback cadence; the normal client callback
bypasses it. Telar does not own the private Core Animation routine's source.

The listing exposes repeated `window`/`drawableSize` property reads and ARC
operations, but not evidence that they dominate. The documented
[ARC return-value handshake](https://clang.llvm.org/docs/AutomaticReferenceCounting.html#arc-runtime-objc-retainautoreleasedreturnvalue)
can eliminate some retain/autorelease work; a source-level temporary is not by
itself proof of a surviving deferred release. No cache-miss counter was measured,
and no SoA/AoS conversion is justified for these few per-window fields.

[C's listing](assembly/drawIfReady-C.s) adds explicit
`objc_autoreleasePoolPush`/`Pop`; it does not replace the system call.
[B's delegate listing](assembly/metalDisplayLink-B.s) obtains `update.drawable`
and calls a separate eligibility method, so its instruction count alone cannot
be compared with the entire baseline path as a performance claim.

## Validation

A, B, C and D ran the existing native window lifecycle test. All four report the
same five image-clipboard failures, already present in A; none adds a window
lifecycle assertion failure. The test exercises deferred preparation, burst
coalescing, no paints while idle, viewport changes, fullscreen, token delivery and
closing in flight. C and D also ran with Metal API validation enabled. Logs are in
[validation](validation). These native tests are not described as green.

The 19 slot-analyzer tests pass. A final ReleaseFast rebuild keeps every
file-backed Mach-O section byte-identical to A, at the same addresses and sizes;
zero-fill sections retain their layouts. The whole `telar` file differs in 176
bytes, all accounted for by `LC_UUID`, two `N_OSO` object timestamps, a cached
object debug path, and the code signature. The benchmark, diagram helper and
CPU-renderer probe binaries are byte-identical in full. See
[section verification](validation/final-sections.json) and
[whole-file hashes](validation/final-equivalence.json). There is no new production
performance claim or changed kernel to remeasure: all candidates were reverted.

Final validation completed successfully: **393/393 build steps; 3,583 tests
passed and two skipped**. The command covered `test`, `test-gui`, `cross`,
`codestyle`, `check-client-boundaries`, `check-model-boundaries` and
`check-programs` with ReleaseFast and `-j2`. The separate native-window test's
pre-existing clipboard failures remain the explicit exception described above.
The [full validation log](validation/final.log) retains warnings from intentional
malformed-input and quota tests as well as the successful final summary.

## Reproduction

Run from the repository root. The patches apply independently to `c8fa3113`.
Build each executable into its own prefix before starting any timing. The slots
and samples below are scratch paths; they must not already exist.

```sh
zig build install build-dod-probe build-bench -Doptimize=ReleaseFast \
  -Ddiagnostics=true -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/draw-A -j2
# Apply exactly one archived candidate patch; build it into /tmp/draw-B.
python3 docs/performance/window-render-worker/scripts/pair_load.py \
  /tmp/draw-A/bin/telar /tmp/draw-B/bin/telar /tmp/draw-pairs 7
python3 tools/gui_slot_probe.py /tmp/draw-A/bin/telar /tmp/draw-slot \
  --workload full --rate 120 --seconds 16 --viewport 1900 1100
python3 docs/performance/drawable-acquisition/scripts/pair_slots.py \
  /tmp/draw-A/bin/telar /tmp/draw-B/bin/telar /tmp/draw-slots 7
python3 -m unittest discover -s tools -p test_slot_probes.py
xcrun llvm-objdump --macho --disassemble --symbolize-operands \
  --dis-symname '-[TelarView drawIfReady]' /tmp/draw-A/bin/telar
```

The inherited pairing script selects `/Library/Developer/CommandLineTools` for
its probe compilation; record the local toolchain when reproducing elsewhere.
