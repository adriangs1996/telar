# C++ client parity status

The Zig GUI remains the compatibility reference. The C++ client implements the
main terminal, workspace, agent, History, machine, clipboard and custom-surface
flows. A missing test matrix is not evidence that a whole subsystem is absent.

## Active delivery scope

1. Finish Preview26: complete.
2. Close concrete graphics and attachment issues: the scoped visibility/resource
   fix is complete.
3. Match native blur behavior: implemented for the Preview27 candidate, with
   macOS numeric-radius fallback and optional Linux compositor support.
4. Compare Release clients under equivalent workloads: in progress on Personal;
   equal-or-better performance is not yet established.

Application state, allocators and compile-time dependency selection remain
separate from native platform adapters. Preserve the current app, configuration
and runtime processes during candidate checks.

## Deferred acceptance

The current phase does not require an exhaustive matrix of styling, themes,
densities, native devices, accessibility or all History/activity states. Physical
system sleep, general macOS framework shutdown retention and additional limit
presentation are deferred. Confirmed faults in the active graphics/attachment
flow or benchmark remain actionable.

Complete functional/visual parity and removal of Telar's Zig sources are not
claimed by finishing this bounded phase. See [DAILY_DRIVER.md](DAILY_DRIVER.md)
and [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).

## Performance

Compare the original Zig GUI and the current C++ Release candidate with equivalent
configuration, fonts, viewport, grid and workload. Use alternated runs without
concurrent build or analysis jobs. Distinguish input-to-visible-presentation
latency, CPU, RSS and throughput; a protocol acknowledgement is not a presentation
endpoint. State which platform and workload were measured, reject invalid runs
and report regressions without weakening the controls.

Raw results, captures and diagnostic files remain outside the repository. Keep
only useful source, tests, fixtures and concise implementation documentation.
