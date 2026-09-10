# Client separation baseline

Reference before implementation, at `beab209f10faa4c7c89f609fc802f4230eb3c310`
plus the pre-existing working changes. Platform: Apple M3, 16 GiB RAM,
macOS 26.6.2, Zig 0.16.0.

## Validation

All commands exited with status 0:

```sh
zig build test-frontend -Doptimize=ReleaseSafe --summary all
zig build test-schema test-transport test-isolation test-compression-isolation -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseFast -Ddiagnostics=true
zig build bench -- --samples 20 --sample-ms 40 --json
```

- Frontend: 1430 tests passed.
- Schema, transport and isolation targets: 228 tests passed in total.
- Production binary built successfully.
- `bench.jsonl` contains the local microbenchmark reference and its parameters.
  This is one run, not the repeated architecture gate or an end-to-end latency
  verdict. It does not establish an allocation or long-running memory baseline.

Full test logs are adjacent to this file. Zig printed `failed command` after
PERF output despite reporting successful targets and returning 0; the recorded
exit status and suite summaries establish the result.

A copy of the binary is retained locally at
`/tmp/telar-client-split-baseline/telar`, with SHA-256
`0e649afca986fd21b93cf01aa0bc03e33956aa437500a1789ee55f00c315ebfd`.
The original patch, status and hashes are retained in that temporary directory.

## Changes excluded from the refactor commits

Existing modifications to `build.zig`, `dev/config.lua`, the Asteroids example
and `src/core/ui/geometry.zig` remain in the worktree. The execution-model
experiment and its plan also remain untracked. Only new build-system hunks
belonging to the client extraction will be staged from `build.zig`.

## Integration scenarios to retain

- Pane snapshot, delta admission and snapshot recovery.
- Pane/tab/workspace lifecycle and geometry, focus before input.
- Key and pointer leases, paste, copy mode and editors.
- Delayed or failed host writes, acknowledgement ordering and stale completion.
- Graphics replacement, credit release and cancellation.
- Configuration, Lua, plugins, clipboard, links and notifications.
- Client detach/reconnect and runtime-owned child survival.

The extraction must preserve the existing TUI tests and add independent
headless client tests. A passing terminal suite alone does not prove separation.
