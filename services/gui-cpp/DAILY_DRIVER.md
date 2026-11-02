# Daily candidate

Current separate macOS Release on Personal: `out-adoption/Telar C++ Preview 27.app`,
relative to the task worktree named in [the handoff](../../docs/gui-cpp-personal-handoff.md).
Its deployed GUI SHA256 is
`eeb50140eb6387a1d211ffa8f1dd7c6d25ad8d4540e480c7513d0f7034ad1617`.
After cleanup on 2026-11-02, Preview8 remains because it is in use; obsolete
previews, including Preview26, were removed. Preview27 and the installed app remain.

From that worktree's root on Personal:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 27.app"
```

Finder can open that same bundle. Other C++ previews share its preview identifier;
close another preview yourself before normal use if needed. The deployed Qt/QML,
runtime/CLI, helpers, configuration lookup and login-shell environment are included.
To return, close the preview and open `~/Applications/Telar.app`. Do not migrate
sessions, remove Zig or change the installed app/configuration as part of this phase.

## What is verified

Preview26 completed the first authorized step. Preview27 adds the scoped image
lifetime correction and native blur alignment. Exact packaged signature/linkage and
1,739-file / 121-Mach-O checks passed, along with disposable schema87/88 launches,
plugins/bars/panels, terminal/Unicode, window flows and 20 normal-loop cycles.
Three alternating native attachment paste/modal captures subsequently passed with
the general clipboard change count unchanged. This is usable-candidate evidence;
full parity, long-running stability and physical sleep are not declared verified.

## Current blockers and limits

The comparative benchmark ran on the exact frozen candidates. Equal-or-better
performance remains unfulfilled: terminal p50 is30.75ms C++ /24.29ms Zig, image1K
54.06 /37.98ms and actual4K124.86 /53.97ms, with six comparable pairs per flow.
C++ also uses more GUI CPU/RSS; see [PARITY.md](PARITY.md) for figures and limits.
The optimization continuation is documented in [OPTIMIZATION.md](OPTIMIZATION.md).
Wrong-size4K, missed fixed-load-rate and invalid presentation runs are excluded.
Raw outputs/helpers stay in ignored `out-dependencies/adoption-benchmark-1`.
No production optimization was accepted; the installed app remains the rollback.

Native shutdown sanitizer failures remain open and unsuppressed; passing assertions
do not erase their exit codes. Qt-only controls reproduce Linux fixture exit
retention. General retention triage and physical suspension are explicitly deferred
for this phase; a direct functional, data-loss, security or memory error in the
scoped graphics/benchmark flows still requires action.

The phase order is Preview26 → graphics/attachments → blur → benchmark. Do not add
new general audit, accessibility or old backlog gates. After delivery, stop this
phase without automatically resuming the old backlog. Full parity and audited
Zig removal remain open, as detailed in [PARITY.md](PARITY.md) and
[ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).
