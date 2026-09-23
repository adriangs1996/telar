---
name: perf-pass
description: Low-level performance pass over telar hot paths -> data layout, cache behaviour, algorithmic waste and generated assembly, with paired measurement and byte-exact equivalence. Use when asked to optimize, save cycles, reduce latency or allocations, inspect assembly or codegen, or review cache misses or memory layout.
---

A **perf pass** turns suspected waste into changes that are measured, proven
equivalent and checked on every target telar ships: macOS and Linux, AArch64
and x86-64. A cycle saved counts only when a paired measurement shows it and
an oracle proves the output did not change.

## Steps

1. **Freeze a baseline.** Before editing anything, build the baseline binaries
   into a scratch prefix (`A`) with ReleaseFast, and read `docs/performance/`
   for earlier experiments and rejected ideas. Done when `A/bin` holds the
   probe and benchmark binaries and you can name what earlier passes already
   tried. Commands: [measurement.md](measurement.md).

2. **Map the hot paths.** Profile the workload (`sample`), and for a wide
   pass fan out one read-only audit per process: runtime (PTY → VT → blit →
   damage → encode), client/TUI (decode → model → compose → diff → emit), GUI
   (renderer, text, widgets) and model/state (per-keystroke and per-frame
   lookups). Every finding carries file:line, work per frame or per event
   (bytes touched, iterations, complexity) and how to measure it. Re-read the
   code behind every agent claim before acting on it: audits find real bugs
   and also overestimate costs by an order of magnitude. Done when each
   candidate is verified and ranked by measured or computed cost.

3. **Run each candidate as an experiment**, one at a time:
   1. Pick or build the **oracle** first: digest comparison, reference model,
      or a test running old and new paths on the same inputs.
   2. Implement the change. Keep semantics exact; when a gain needs a
      semantic change, stop and hand the decision to the user with the
      measured cost.
   3. Oracle green, then paired timing against the previous accepted build.
   4. Read the hot loop's disassembly: [assembly.md](assembly.md).
   5. Accept or reject by the rule in [measurement.md](measurement.md).
      Record rejected variants and why.
      Done when the candidate is accepted with evidence or rejected with the
      regression that killed it. Patterns that recur: [patterns.md](patterns.md).

4. **Cross the architectures.** For every construct whose lowering depends on
   the target (vector reductions, wide loads, bit tricks), compile the kernel
   for `aarch64`, `x86_64` baseline and `x86_64_v3` and compare. Select per
   architecture at comptime when the best forms diverge. Run the touched
   tests as x86-64 under Rosetta. Done when each such construct has a
   verified lowering on all three targets.

5. **Validate the tree.** `zig build test`, `test-gui`, `cross`, `codestyle`,
   `check-client-boundaries`, `check-model-boundaries`, `check-programs`, and
   every new oracle test. Done when all are green and the final build is
   re-measured against `A` across every mode and benchmark, including those
   you did not target.

6. **Write the report** in `docs/performance/<pass-name>/README.md`: changes,
   paired tables with win counts, disassembly findings, rejected variants,
   regressions with their cause or "cause not established", and measured
   findings left for a user decision. Done when every number in it comes from
   a run in this pass.
