# telar CLI

`telar`, the command line people and agents type. It implements help, agent
hooks, agent CLI integration, plugin packages, proxy CA trust, and `server` to
start, find, bridge and stop the runtime. Window commands cover `client`,
`sidebar`, `workspace-list`, `layout`, `notification`, `command suggest`,
`config` and configured plugins; the rest of the Zig CLI is being ported. It
talks to the runtime over its socket with `telar-client` and shares code with the
runtime and GUI through `dlls/`; it never includes `services/runtime-cpp`.

`hook` runs on every agent event, so `telar` stays small: it links libssl and
libcrypto beside the system libraries, without the runtime's terminal engine,
SQLite, pcap or frameworks. `telar server` (without `stop`, `endpoint` or `bridge`)
replaces itself with the `telar-runtime` installed beside it.

The runtime's build includes this directory and writes `telar` next to
`telar-runtime`. To build only the CLI:

```sh
cmake -S . -B out -G Ninja -DCMAKE_BUILD_TYPE=Release -DGHOSTTY_VT_ROOT=/path/to/libghostty-vt
cmake --build out
ctest --test-dir out --output-on-failure
```

`config check` execs the sibling `telar-config-check`, installed beside `telar`.
The helper links `telar-config`, Lua and libghostty for agent icon width validation;
these dependencies are kept out of the hook process. Its Lua bootstrap lives in
`config/bootstrap.lua` and has no build dependency on the retired Zig tree.

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
