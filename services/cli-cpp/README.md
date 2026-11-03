# telar CLI

`telar`, the command line people and agents type. It implements help, agent
hooks, agent CLI integration, machines and SSH dispatch, CLI installation, window
startup, plugin packages, proxy CA trust, and `server` to start, find, bridge and
stop the runtime; the remaining command families are being ported. It talks to the runtime over its socket with `telar-client`
and shares code with the runtime and the GUI through `dlls/`; it never includes
`services/runtime-cpp`.

`hook` runs on every agent event, so `telar` stays small: it links libssl and
libcrypto beside the system libraries, without the runtime's terminal engine,
SQLite, pcap or frameworks. `telar server` (without `stop`, `endpoint` or `bridge`)
replaces itself with the `telar-runtime` installed beside it.

The runtime's build includes this directory and writes `telar` next to
`telar-runtime`. To build only the CLI:

```sh
cmake -S . -B out -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build out
ctest --test-dir out --output-on-failure
```

The C++ `telar` is replacing the Zig CLI command by command;
[parity.md](parity.md) records what each command does today and how it is
compared with Zig. `help/` holds every help text `telar` prints, and `tools/`
the parity and latency checks.

## Agent hooks

`telar hook claude|codex|pi|cursor|opencode [--socket PATH]` consumes the
provider's JSON from standard input. It connects to an existing runtime and
verifies the reporter's pane ancestry before sending progress, lifecycle, title
and command observations. Lifecycle failures leave the agent running and exit
successfully. Claude's worktree hooks also work outside a pane: creation returns
the checkout path, while removal retains a checkout with local changes. Their
failures are reported explicitly. `telar integration install` writes the provider
files that run it.

Set `TELAR_HOOK_TRACE` to a new output path for one Debug hook invocation to
trace input reading, report mapping, sending and worktree operations. Release
hooks ignore this variable.

## Machines and window startup

Machine profiles use the same private `machines.json` format, locks and atomic
replacement as Zig. `--machine LABEL COMMAND...` carries shell-neutral base64url
words over managed SSH; `dispatch-argv` restores argv and preserves standard
streams and exit status. No command requires a Zig binary or source directory.

Machine installers, configuration filters, login orchestration and window startup
live in the sibling `telar-launch.so` module. The CLI loads it only for these
commands; hooks, help and runtime bootstrap do not load it. CMake installs the
module beside `telar`; copying a distribution must keep `telar`, `telar-launch.so`
and `telar-runtime` together. The `.so` filename is the same on macOS and Linux.
The loader checks its entry-point ABI before calling it.

For a window, the CLI resolves its real executable through symlinks, then looks
for executable `telar-gui` beside it, then `../../MacOS/telar-gui` (the inverse
of the GUI's `Contents/Resources/bin/telar` lookup), then searches PATH. It execs
the GUI with literal argv, the current working directory and the selected socket.
It starts the sibling runtime with configuration/profile/fresh options when
needed; `--fresh` refuses an existing runtime. `gui --login-shell` adopts the
login shell environment once before this startup.

`machine setup --binary PATH` needs `telar-runtime` and `telar-launch.so` beside
that CLI, built for the target machine. Its version directory includes hash
prefixes of all three artifacts, so changing a companion identifies a different
build. Companion transfers verify SHA-256 before replacement, and setup repairs
a missing companion. Release archives must contain all three artifacts; the
installer refuses archives missing the C++ companions instead of deploying a
monolithic Zig release. Agent assets and skills are embedded from
`integration/assets/`; the build does not read `src/`.

See [the port report](machines-launch-report.md) for comparisons, retained tests
and the remaining setup verification boundaries.
