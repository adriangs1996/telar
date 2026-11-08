# telar CLI

`telar`, the command line people and agents type. It implements help, agent
hooks, agent CLI integration, machines and SSH dispatch, CLI installation, window
startup, plugin packages, proxy CA trust, sessions (`workspace`, `tab`,
`worktree`), `pane` and `agent`, execution, file/repository transfer, project
setup, runtime inspection, diagnostics, history, the native API schema, and the
window commands (`client`, `sidebar`, `workspace-list`, `layout`,
`notification`, `command suggest`, `config` and configured plugins). `server`
starts, finds, bridges and stops the runtime. It talks to the runtime over its
socket with `telar-client` and shares code with the runtime and GUI through
`lib/`; it never includes `src/runtime-cpp`.

`hook` runs on every agent event, so `telar` stays small: it links libssl and
libcrypto beside the system libraries, without the runtime's terminal engine,
SQLite, pcap or frameworks. `telar server` (without `stop`, `endpoint` or `bridge`)
replaces itself with the `telar-runtime` installed beside it.

The runtime's build includes this directory and writes `telar` next to
`telar-runtime`. To build only the CLI:

```sh
../../tools/cpp configure cli --config Release
cmake --build out
ctest --test-dir out --output-on-failure
```

`config check` execs the sibling `telar-config-check`, installed beside `telar`.
The helper links `telar-config`, Lua and libghostty for agent icon width validation;
these dependencies are kept out of the hook process. Its Lua bootstrap is
`lib/telar-config/bootstrap.lua`, shared with the runtime and the GUI.

`help/` holds every help text `telar` prints, and `tools/` the regression and
latency checks.

[Execution and runtime contracts](exec-runtime.md) documents the interfaces for
remote machine/worktree commands, the deliberate native wire differences and
the remaining runtime gaps. Repository preparation still needs the machine
family's profile listing and dispatch entry point to be integrated.

## Reproducible C++ modules build

Use the [shared toolchain and module guide](../../docs/build/cpp-modules.md)
for a clean clone, pinned bootstrap, configure/build/test commands, diagnostics
variants and clangd. The compiler and tools are selected by `tools/cpp` on both
macOS and Linux. C++ module sources are primary; Qt/moc, Objective-C++, generated
interfaces and preprocessor contracts retain documented textual boundaries.

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

Machine profiles live in a private `machines.json` with locks and atomic
replacement. `--machine LABEL COMMAND...` carries shell-neutral base64url
words over managed SSH; `dispatch-argv` restores argv and preserves standard
streams and exit status.

Machine installers, configuration filters, login orchestration and window startup
build as the static `cli-launch` library, linked into `telar`.

For a window, the CLI resolves its real executable through symlinks, then looks
for executable `telar-gui` beside it, then `../../MacOS/telar-gui` (the inverse
of the GUI's `Contents/Resources/bin/telar` lookup), then searches PATH. It execs
the GUI with literal argv, the current working directory and the selected socket.
It starts the sibling runtime with configuration/profile/fresh options when
needed; `--fresh` refuses an existing runtime. `gui --login-shell` adopts the
login shell environment once before this startup.

`machine setup --binary PATH` needs `telar-runtime` and `telar-config-check` beside
that CLI, built for the target machine. Its version directory includes hash
prefixes of all three artifacts, so changing a companion identifies a different
build. Companion transfers verify SHA-256 before replacement, and setup repairs
a missing companion. Release archives must contain all three artifacts; the
installer refuses archives missing the C++ companions. Agent assets and skills
are embedded from `integration/assets/`.

## Editor

`just editor` configures `out/` (with `out/compile_commands.json`) for clangd, as it
does for every library; `.clangd-build.json` re-runs that configuration on save.
