# Record placement benchmark

The maintained form of the [archived experiment](README.md): the same two
idle-delivery fixtures, with the address of their large allocations chosen by
arguments of `telar-benchmarks`, and a runner that pairs the choices inside one
executable. It is benchmark tooling. Nothing in `src/` changed for it, no
application build contains it, and its allocator is scratch storage for an
experiment, not a pool.

## What it measures

`backend.delivery.flush_idle_2x8` and `backend.delivery.flush_idle_1x32` time
the flush that ends every runtime update, on a runtime whose clients have
caught up with every pane: two clients on eight panes, and one client on 32.
An idle flush sends nothing; it walks each client's attachments and each pane
and finds no work. Every variant builds that same fixture and runs that same
compiled flush. The only thing a variant changes is the address at which the
fixture's large allocations start.

It does not measure:

- why placement changes the time. Records that all start at the same offset of
  a page may compete for the same cache sets; nothing here counts cache misses,
  so that stays a hypothesis. There is no PMU result.
- a production allocator. No variant reuses freed records, releases segments
  or accounts for retained memory.
- active output, input latency or frame rate. An idle-flush change predicts
  none of them.
- other hosts. Page size, cache geometry and the backing allocator's own
  placement differ; a result belongs to the machine that produced it.

A run with no speedup is a valid result.

## Options

All of them apply only to the idle-delivery cases. Without them the cases
build their fixture from the benchmark's debug allocator exactly as before.

| Option | Meaning |
| --- | --- |
| `--placement baseline` | Default. Allocations go to the backing allocator untouched. |
| `--placement shift` | Control. Every controlled allocation starts a quarter window past what the backing returned, so all of them still share one offset. |
| `--placement stagger` | Each controlled allocation of one length starts one stride past the previous one, wrapping at the window. |
| `--placement pack` | Controlled allocations are carved back to back from one region, each at the next address its alignment allows. Offsets follow from the sizes. |
| `--placement-backing debug\|libc` | The allocator underneath. `debug` is the default and what every other case uses. |
| `--placement-threshold <bytes>` | Smallest allocation controlled. Default 32768. |
| `--placement-stride <bytes>` | Step between staggered offsets, and the largest alignment controlled. A power of two, default 512. |
| `--placement-window <bytes>` | Span the offsets spread over, and the slack `shift` and `stagger` add to each controlled allocation. A power of two of at least four strides. Default: the page size the host reports. |
| `--placement-report` | With `--json`, emit the records described under [Report](#report). |
| `--intervening-walk <bytes>` | With `--json`, read this much unrelated memory before each flush and time every flush on its own. |

An invalid value stops the program before any case runs, with the usage text
and a named error such as `InvalidPlacementWindow`.

The policy selects by shape, never by type: an allocation is controlled when
its length reaches the threshold and its alignment fits in the stride. With
the default threshold that is every pane, attachment and session and the
runtime itself, and also every other allocation that large, whatever it holds:
those records are 27 of the 124 allocations controlled in the smaller fixture
and 66 of 296 in the larger. `--placement-report` lists all of them. A
threshold between the size of an attachment and the size of a pane leaves
attachments where the backing allocator put them.

The window defaults to the host's page size because that is a fact the program
can read, not because one page is the right span on every processor. Pass
`--placement-window` to test another.

Names in the archive map to these: `none` is `baseline`, `color` is `stagger`,
and the `TELAR_BENCH_*` variables became the options above. No environment
variable selects anything.

## Limits of the allocator

- `pack` reserves 1 GiB of address space per case, backs pages as records
  touch them and never reuses a freed record's bytes. The region is returned
  when the case ends. An allocation that does not fit is refused, and the case
  fails with `PlacementRefusedAllocation`.
- `shift` and `stagger` ask the backing allocator for one extra window per
  controlled allocation.
- At most 2048 controlled allocations are alive at once; one more is refused
  the same way. The 1x32 fixture holds 296.
- A controlled allocation is never resized in place.
- `stagger` keeps one sequence per allocation length, for 32 lengths; any
  further length stays at offset zero.

## Runner

`tools/placement_bench.py run` builds the executable into a new output
directory, runs every variant once per round and writes `results.json`. Each
round starts one variant later than the previous one, and odd rounds run in
reverse, so no variant always follows the same neighbour.

Each run:

- gets the placement through arguments and exactly this environment:
  `PATH=/usr/bin:/bin`, `HOME=<output>/home`, `LANG=C`. Nothing the calling
  shell exported reaches it.
- keeps its standard output and error in `<output>/runs/`.
- counts only if it exits zero, reports its cases, is still idle after timing
  (`quiet`, no send pending), holds the records its shape requires and returns
  every controlled allocation at teardown. A run that does not count stays in
  `results.json` with its exit status and the reasons, and its round is left
  out of that variant's pairs.

The runner also fails when counted runs disagree on the record layout, the
fixture shape, the set of cases or the benchmark's own metadata.

`results.json` records the source revision with its modified and untracked
paths, the build command with its exit status and the `DEVELOPER_DIR` and
`SDKROOT` it ran under, the executable's SHA-256, the host, page size and load
averages, the settings and variants, every run and the derived statistics.
`units` names what each number is. A paired change compares a variant with the
reference variant's run of the same round; the table prints its median, its
range and how many pairs the variant won.

`tools/placement_bench.py replay <results.json>` recomputes the statistics from
the saved runs and fails if they differ from the stored ones.

With `--binary <path>` the runner skips the build. It still records the
checkout's revision, which then says nothing certain about that executable.

## Commands

A short smoke comparison, under a minute after the build:

```sh
python3 tools/placement_bench.py run --output "$SCRATCH/placement-smoke" \
  --jobs 2 --rounds 2 --samples 4 --sample-ms 20
```

The fuller paired run, with the archive's five variants:

```sh
python3 tools/placement_bench.py run --output "$SCRATCH/placement-full" \
  --jobs 2 --rounds 9 \
  --variant baseline=baseline --variant shift=shift \
  --variant stagger_panes=stagger:65536 --variant stagger=stagger \
  --variant pack=pack
python3 tools/placement_bench.py replay "$SCRATCH/placement-full/results.json"
```

The same with a walk between flushes, reusing the executable already built:

```sh
python3 tools/placement_bench.py run --output "$SCRATCH/placement-walk" \
  --binary "$SCRATCH/placement-full/prefix/bin/telar-benchmarks" --rounds 9 \
  --intervening-walk 524288 \
  --variant baseline=baseline --variant shift=shift \
  --variant stagger_panes=stagger:65536 --variant stagger=stagger \
  --variant pack=pack
```

One variant by hand, with the report:

```sh
env -i PATH=/usr/bin:/bin HOME="$SCRATCH" LANG=C \
  "$SCRATCH/placement-full/prefix/bin/telar-benchmarks" \
  --filter backend.delivery.flush_idle --json --placement stagger \
  --placement-backing libc --placement-report
```

The allocator's and the runner's tests, which measure nothing:

```sh
zig build test-bench-placement
```

`zig build test` runs them too. Check `uptime` before timing, and let the
build finish first; the runner does both steps in order.

## Report

`--placement-report` adds these JSON Lines, all written before the first timed
sample of a case or after its last one:

| `type` | When | Content |
| --- | --- | --- |
| `placement_policy` | once | Mode, backing, threshold, stride, window, shift offset, the host's page size, the allocator's bounds. |
| `placement_layout` | once per record type | Size, alignment, whether the policy selects that shape, and every field's offset and size, for the pane, attachment, cell sync, session, runtime and runtime model. |
| `placement_fixture` | per case, before timing | Shape, and how many allocations and bytes the placement controls. |
| `placement_records` | per case and record kind | One array per column: slot, address, offset in its page and in the window, and whether the placement controls it. |
| `placement_allocations` | per case | Address, length and applied offset of every controlled allocation, records or not. |
| `placement_idle` | per case, after timing | Whether every client is still quiet and how many sends are pending. |
| `placement_teardown` | per case, after the fixture is freed | Controlled allocations made, still live and refused. |

The record types are read from the runtime model's own columns in
`benchmarks/placement_report.zig`, so the runtime carries no reporting code.

## Intervening walk

`--intervening-walk <bytes>` reads one byte every 64 across that much memory
before each flush, takes the clock on both sides of the flush, then repeats the
read and takes the clock twice with nothing between. The `intervening_walk`
line gives both sums and the flush count, calibration and warmup included:
`flush_ns` and `empty_clock_ns`. The runner divides each by the flushes and
also reports their difference, labelled as derived.

The walk makes each flush start after unrelated memory traffic. How much of
the fixture it displaces from which cache is not measured, so its size names
no cache level and the mode is not a cold-cache measurement. In this mode
`median_ns_per_op` of the benchmark line includes the walks themselves and is
not a flush time.

## Fresh validation

Run on 2026-10-02 on the machine called Personal, with the maintained tooling
at revision `94d2d46e`. It is a different machine and a different executable
from the archive's: the [M3 numbers](README.md#warm-idle-delivery) are not a
target these reproduce or miss. Each table below stands on its own.

| | |
| --- | --- |
| Host | Apple M1 Pro, 10 logical CPUs, macOS 26.6.2, 16 KiB pages |
| Toolchain | Zig 0.16.0, `zig build build-bench -Doptimize=ReleaseFast -j2 --libc <file>` (see [the host note](#building-on-this-host)) |
| Executable | SHA-256 `b14d29a9619f04bc374a2c28d4eca250785a61ae584590637c6e408b9b6a9f7c`, built by the runner from a tree with no modified tracked file; the walk run reused it |
| Settings | 9 rounds, 12 samples of 40 ms, `libc` backing, threshold 32768, stride 512, window 16384 |
| Load | 1-minute average between 2.2 and 3.7 during the runs; the host was shared with other work |
| Runs | 45 of 45 counted in each run set; `replay` matches both |

The results are [warm-results.json](validation-personal/warm-results.json)
and [walk-results.json](validation-personal/walk-results.json): provenance,
every run's parsed lines and the statistics. Each run's raw output stayed in
the runner's scratch directory and is not in the repository; the `stdout` and
`stderr` paths in those files point there.

### Where the records landed

| Record | Size | Alignment |
| --- | ---: | ---: |
| Pane | 836,696 B | 8 |
| Attachment | 42,536 B | 8 |
| Session | 1,096,256 B | 16 |
| Runtime | 4,718,504 B | 8 |

Under `baseline` with `libc`, every pane, attachment, session and the runtime
starts at offset 0 of a page, in both fixtures. `shift` puts all of them at
4096. `stagger` puts panes at 0, 512, 1024 and so on, and attachments on the
same sequence of their own, so the 32 panes of the larger fixture take 32
different offsets. `pack` leaves panes 1,776,640 bytes apart, which is 7168
past a whole number of pages, so consecutive panes start at 3328, 10496, 1280,
8448 and so on within their page. That sequence repeats after 16 panes: the 32
panes share 16 offsets in pairs. The stride comes from the sizes of what is
allocated between two panes and changes whenever those do.

The placement controls more than the records: 124 allocations and 43.4 MB in
the 2x8 fixture, 296 allocations and 71.8 MB in 1x32. `stagger_panes` raises
the threshold to 65536, which leaves the attachments at offset 0 and still
places panes, sessions, the runtime and every other allocation that large (107
and 263 allocations).

### Flushes back to back

Median over nine runs of each run's median, in nanoseconds per flush. The
paired column is the median of the nine changes against `baseline` in the same
round, with their range and the rounds the variant was faster.

| Fixture | Variant | ns per flush | Paired change | Range | Faster |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 clients × 8 panes | baseline | 1,016 | | | |
| | shift | 1,001 | -1.07% | -2.9 to +1.6% | 5/9 |
| | stagger_panes | 992 | -1.97% | -6.1 to -0.4% | 9/9 |
| | stagger | 924 | -7.32% | -11.1 to -6.4% | 9/9 |
| | pack | 924 | -9.53% | -10.4 to -3.5% | 9/9 |
| 1 client × 32 panes | baseline | 1,212 | | | |
| | shift | 1,199 | -0.65% | -5.8 to +7.4% | 5/9 |
| | stagger_panes | 1,010 | -16.00% | -24.2 to -9.3% | 9/9 |
| | stagger | 781 | -34.88% | -38.9 to -29.5% | 9/9 |
| | pack | 814 | -32.92% | -35.8 to -27.3% | 9/9 |

On this machine the uniform shift does not move either fixture, and spreading
the offsets makes the idle flush faster in every round: by about a third with
32 panes and by under a tenth with eight. The direction matches the archive;
the sizes do not, and nothing here says why.

### Flushes after a 512 KiB walk

Nanoseconds per flush from the walk's own sums: the flush interval, the empty
clock interval, and their difference, which the paired columns use.

| Fixture | Variant | Flush interval | Empty clock | Difference | Paired change | Range | Faster |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 clients × 8 panes | baseline | 1,111 | 23.6 | 1,088 | | | |
| | shift | 1,099 | 23.5 | 1,076 | -0.37% | -6.5 to +5.9% | 6/9 |
| | stagger_panes | 1,087 | 23.2 | 1,064 | -1.66% | -7.7 to +3.9% | 7/9 |
| | stagger | 1,095 | 23.6 | 1,072 | -1.40% | -6.6 to +3.5% | 7/9 |
| | pack | 1,093 | 23.7 | 1,070 | -0.37% | -7.2 to +4.8% | 6/9 |
| 1 client × 32 panes | baseline | 1,257 | 24.7 | 1,233 | | | |
| | shift | 1,273 | 24.5 | 1,248 | +0.83% | -3.7 to +5.2% | 4/9 |
| | stagger_panes | 1,196 | 24.6 | 1,171 | -5.57% | -9.7 to -1.9% | 9/9 |
| | stagger | 1,061 | 24.7 | 1,036 | -16.53% | -18.6 to -13.5% | 9/9 |
| | pack | 1,096 | 24.2 | 1,072 | -13.10% | -18.0 to -12.3% | 9/9 |

After a walk the eight-pane fixture shows no consistent difference between
placements. The 32-pane fixture keeps about half of its back-to-back gain.

### The default cases

The two cases with no placement option, against an executable frozen from the
tree before this work (`23e9afc6`, SHA-256
`214cb8a0b04650f1b41c42150272b406580b60dae21a0e0fda405d92cf2abb5c`), with
`.agents/skills/perf-pass/scripts/bench_pair.py` and 12 pairs:

| Case | Before | After | Paired change | After faster | Minimum before | Minimum after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `flush_idle_2x8` | 1,029 | 1,045 | +1.5% | 4/12 | 999 | 1,018 |
| `flush_idle_1x32` | 1,151 | 1,158 | +1.2% | 3/12 | 1,117 | 1,126 |

An earlier session with the same sources apart from one error's name gave
+1.1% (4/12) and -0.4% (6/12). Neither case loses consistently by the perf
pass rule, and a change of about one percent is within what two sessions on
this host differ by. The flush is the same source, now compiled into
`flushIdle` instead of into `execute`; whether that accounts for the eight-pane
case leaning slower is not established. The full default suite runs its 31
cases in the same order and emits only `metadata` and `benchmark` lines.

### Building on this host

The tree at `23e9afc6`, before any change, does not build `build-bench` here
with the SDK Zig finds by itself. Xcode's macOS 27.0 SDK fails the libc++
sub-compilation and the `@cImport` of `libproc.h` in `lib/proclineage`; the
Command Line Tools' 26.5 SDK fails the same `@cImport`, on static assertions in
`mach/message.h`. The 15.4 SDK's headers build. Every build in this validation
therefore passed a libc file naming that SDK, in the form
`packaging/macos/sdk-libc.sh` writes:

```sh
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
printf 'include_dir=%s/usr/include\nsys_include_dir=%s/usr/include\ncrt_dir=%s/usr/lib\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n' \
  "$sdk" "$sdk" "$sdk" > "$SCRATCH/macos-libc.txt"
python3 tools/placement_bench.py run --output "$SCRATCH/placement-full" --jobs 2 \
  --zig-build-arg=--libc --zig-build-arg="$SCRATCH/macos-libc.txt" --rounds 9 ...
```

This is a fact about this host's SDKs, recorded in `provenance.build.command`.
A host whose default SDK builds the tree needs no `--zig-build-arg`.

## Limits of this evidence

- One machine, one session, a shared host. Nine rounds give per-run medians;
  nothing here establishes a tail-latency distribution.
- No PMU counters, no Linux and no x86-64 measurement. The cache-set
  explanation remains untested.
- The backing allocator decides the baseline. `libc` on this macOS returns
  these sizes page-aligned; another allocator or system may already spread
  them, and then `baseline` is a different experiment.
- Each run is one process with one address-space layout. Rounds repeat it, but
  the fixture's own allocation order is the same every time.
- The walk's 512 KiB and its 64-byte step are inputs, not properties of this
  processor's caches.
- The archive's [synthetic layout kernel](source/kernel/layout_kernel.zig) was
  not ported; it is not needed to reproduce the flush benchmark and stays an
  archived artifact.
