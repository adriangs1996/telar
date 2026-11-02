# C++ GUI work on Personal

## Authorized phase

Continue in order: finish Preview26, close concrete graphics/attachment issues,
match native blur, then run the full-client comparative performance benchmark.
Preview26 and the scoped graphics fixes are complete; Preview27 contains blur.
Benchmarking is in progress and equal-or-better performance is not established.
Do not restart the older backlog or remove Zig/runtime/CLI/plugin-worker code as
part of this phase. Broader visual/accessibility work, physical sleep and general
framework shutdown-retention triage are deferred.

Use the existing `gui-cpp-parity-personal-20261029` worktree on Personal. Preserve
installed apps, user configuration, active runtimes and verification processes.
Do not publish, rewrite imported history or create additional agents/worktrees.
Local reviewed commits may be brought into `feat/desktop-lua-ui` incrementally.

## Source requirements

Keep application/domain code separate from native macOS/Linux adapters. Reuse
components, inject allocators, and use concepts/templates for dependencies without
new virtual dispatch. Preserve the clang-tidy profile and `.clangd` configuration.
Use descriptive names, logical blank lines, braced conditions and focused tests.
Send factual Spanish progress updates at least every 60 seconds.

## Generated output

Adrian explicitly requested removal of generated measurement archives from every
checkout. Keep required test tools in `tests/` or `tools/`; put temporary helpers,
captures, logs, copies of sources and benchmark results in ignored build directories
or temporary directories outside the repository. Do not version those outputs or
restore the historical archive directories in future updates.

Let a timed run finish before cleanup that would invalidate it. Preserve genuine
user-authored notes privately outside the generated-output tree without reading
or publishing their contents. Do not delete production code, test fixtures,
previews or live runtime state while removing artifacts.

See `services/gui-cpp/README.md`, `DAILY_DRIVER.md`, `PARITY.md` and
`ZIG_RETIREMENT.md` for the maintained build instructions and current scope.
