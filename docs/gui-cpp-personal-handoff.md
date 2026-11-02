# Next GUI performance task on Personal

For the 2026-11-02 complete-stack task, start with
[cpp-performance-flows.md](cpp-performance-flows.md). Its current scope compares
C++ runtime + GUI against Zig runtime + GUI, including the 120 Hz smoothness goal.
The first phase establishes flows and baselines before per-flow optimization.

The previous parity agent finished at `089a07dcd6cd719f80c56625652afacb87060635`;
its result was integrated by `36adb7d4f7be59c79323396db4fd8ac54142f48d`.
The benchmark failed equal-or-better performance. The measured regressions,
invalid runs and rejected approaches are preserved in
[OPTIMIZATION.md](../services/gui-cpp/OPTIMIZATION.md) and
[PARITY.md](../services/gui-cpp/PARITY.md).

## Start from current source

Adrian requested complete removal of the previous Personal environment on
2026-11-02. Its task/session, linked checkout, previews, build outputs, frozen
executables, raw measurements, private runner adaptations and Linux VM were removed.
The old task was `gui-cpp-parity-personal-20261029`. Its historical Git commits
remain available; they are not the next task's starting revision.

For the next dispatch to machine `Personal`:

1. Include the intended current local changes in the source revision before dispatch.
   Only commits travel between machines. Record the exact SHA.
2. Create a new task branch and clean checkout explicitly from that revision.
   Personal's pre-existing main checkout is not the source of truth for this work.
3. Provision the compiler/SDK, Qt, Ghostty and required tools from declared inputs;
   use [README.md](../services/gui-cpp/README.md), then qualify the measurement
   controls in [OPTIMIZATION.md](../services/gui-cpp/OPTIMIZATION.md).
4. Establish a fresh C++/Zig comparison before changing performance behavior.
   Build any required Linux test environment as new task-owned infrastructure.

Use the recorded findings to avoid repeating rejected experiments. All executable
inputs and generated output for a new run must belong to that run, with identified
source versions and build options. Preserve the installed app, user configuration
and long-lived runtime/PTYs; run measurements with isolated owned sessions.

This document prepares a future dispatch; it does not request starting another agent.
