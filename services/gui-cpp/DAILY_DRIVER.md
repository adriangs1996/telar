# Daily C++ client adoption

There is no retained candidate environment from the previous Personal task.
Adrian requested its removal on 2026-11-02, including Preview8, Preview27, the
checkout, raw benchmarks, dependencies and Linux VM. The installed Telar app and
user runtime remain separate from that cleanup.

Build the current source using [README.md](README.md). Run the resulting
`out/telar-gui`, or create a separately named macOS package using
`tools/package_macos.py`. A new performance task must start from a fresh checkout
of the current committed revision; see
[the dispatch handoff](../../docs/gui-cpp-personal-handoff.md).

## Historical qualification and current limits

Preview26 completed the initial daily-use checkpoint. Preview27 added the scoped
graphics lifetime fix and native blur alignment. The agent reported packaged
signature/linkage checks, disposable schema87/88 launches, plugins/bars/panels,
terminal/Unicode and 20 normal-loop cycles passing. Three paired attachment
paste/modal captures passed with the general clipboard count unchanged.

The historical full-client benchmark failed performance acceptance. These results
describe those deleted candidates, not a new build of this branch.
[PARITY.md](PARITY.md) records the figures and limits;
[OPTIMIZATION.md](OPTIMIZATION.md) records rejected approaches and the next setup.

Full parity, sustained daily stability and physical suspend are not declared
verified. Native shutdown sanitizer failures remain recorded and unsuppressed;
general framework exit-retention triage is deferred. Additional feature inventory
and runtime/CLI/plugin-worker replacement are outside the performance task.
Zig retirement remains a separate audited stage in [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).
