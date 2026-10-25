# C++ runtime

An independent C++23 runtime for macOS ARM64. It handles all 62 client request
tags, including Desktop's `HoldTab`. The Zig runtime remains the
compatibility reference. This executable is opt-in. An installation option
provides the `telar` command used by Desktop's existing discovery.

## Build and run

The initial target requires macOS 26 and its SDK, CMake, Ninja, a C++23
compiler, Python 3, libpng, OpenSSL 3, nghttp2, Brotli and Zstd headers/libraries,
and Zig 0.16.0. SQLite and zlib come from the macOS SDK. Zig builds only
libghostty-vt for production; the executable links no
Telar Zig runtime code.

From this directory:

```sh
python3 tools/build_ghostty.py --build-dir dependencies/ghostty --prefix dependencies/install
cmake -S . -B out -G Ninja -DCMAKE_BUILD_TYPE=Release -DGHOSTTY_VT_ROOT="$PWD/dependencies/install"
cmake --build out
ctest --test-dir out --output-on-failure
runtime_directory=$(mktemp -d)
out/telar-runtime --socket "$runtime_directory/runtime.sock"
```

Pass `-DCMAKE_CXX_COMPILER=/path/to/clang++` if the default compiler lacks the
C++23 features used by Desktop's shared protocol serializers. The measured
build uses LLVM 23.1.2; see [performance.md](performance.md) for the host,
binary hashes, comparisons and limitations.

Pass `-DOPENSSL_ROOT_DIR=/path/to/openssl-3` when the default installation is
OpenSSL 4. The TLS allocation adapter requires immediate global cleanup while
its injected allocator is alive. OpenSSL 4 defers that cleanup to a process
exit destructor, so this implementation explicitly requires major version 3.
See the [OpenSSL 4 cleanup contract](https://docs.openssl.org/4.0/man3/OPENSSL_init_crypto/).
Runtime proxy startup, authenticated CONNECT, opaque/TLS forwarding and pane
environment injection are connected. HTTP/1 framing and exchange ordering are
implemented. HTTP/2 inspection and stream tracking are integrated; the reference
comparison uses nghttp2 1.70.0. Set `-DNGHTTP2_ROOT=/path/to/nghttp2` if CMake
cannot find its headers and static library. HTTP/1 and HTTP/2 capture, bounded
delivery, background decoding and joining are integrated. Capture can be enabled
independently of interception. System-trust management, CA rotation and runtime
authority selection pass 62 cross-runtime cases with injected system-command
execution. Complete proxy-to-plugin integration coverage remains open.

Capture storage, joining, bounded publication and content decoding have
independent C++ implementations. Their libraries use injected allocation
callbacks. The current dependencies are Brotli 1.2.0, Zstd 1.5.7 and SDK zlib
1.2.12. Pass `-DBROTLI_ROOT=/path/to/brotli` and `-DZSTD_ROOT=/path/to/zstd` when
CMake cannot find them. The capture pipeline accepts a tap through a template
concept; with no configured tap it joins and releases captures without decoding
their bodies. Small gzip, deflate and Zstd pass the paired Zig comparison;
small Brotli and whole-runtime proxy acceptance remain open.

The dependency script fetches Ghostty commit
`a4edca2a90d6cf89900bb058e71cb6860cec78c5`, applies
[vendor/ghostty-vt-state.patch](vendor/ghostty-vt-state.patch), and installs
libghostty-vt. `--source /path/to/pinned/ghostty` copies an existing source tree
instead; that tree must match the pinned revision. The patch extends the C API
with terminal state, bounded grapheme access, graphics enumeration, deletion
and placement anchors. It contains no Telar runtime services.

CMake links the static Ghostty library and generates raw-cell accessors from
its type manifest. Changing the dependency requires regenerating those
accessors; no offsets from a different Ghostty build are assumed.

For an installation independent of Homebrew's dynamic libraries, configure a
fresh Release build with `-DTELAR_RUNTIME_DISTRIBUTABLE=ON`, keeping the same
compiler and dependency prefixes. This requires static OpenSSL 3, libpng,
nghttp2, Brotli, Zstd and Ghostty archives. Each link runs the project's macOS
dependency check and rejects non-system dynamic libraries. A cached dynamic
dependency causes a configuration error instead of silently being retained.
The minimum deployment target defaults to macOS 26.0.

`cmake --install out-distribution --prefix /path/to/staging` installs
`bin/telar-runtime`. Add `-DTELAR_RUNTIME_INSTALL_DESKTOP_COMMAND=ON` when
configuring to install it as `bin/telar` instead. Desktop already looks for
that command beside its executable, in `Contents/Resources/bin`, then through
the login shell's PATH. Choose a private staging directory when testing a
replacement. Signed archives, bundled dependency notices and a complete
Desktop application package remain pending.

The manually dispatched [C++ runtime workflow](../../.github/workflows/runtime-cpp.yml) builds
Release and Debug with ASan/UBSan on macOS ARM64, runs runtime/TLS/hook tests
and exercises the installed command through Desktop's discovery code. It
does not run on pushes or pull requests. Hosted CI acceptance remains pending;
shared CI runners are not used for performance acceptance. Sanitizer builds
need the compiler's runtime library and cannot enable the distribution check.

The socket directory must belong to the current user and prohibit writes by
other users. The socket has mode `0600`; accepted peers must have the same UID.
An owned lock file prevents competing runtimes from replacing a live socket.

The history path follows `TELAR_HISTORY`, then `XDG_DATA_HOME/telar/history.db`,
then `HOME/.local/share/telar/history.db`. `--history` overrides it. Use
`--history :memory: --no-session` for a disposable store. Database files use mode `0600`. The schema is compatible with
version 5 of Telar's existing database.

## Editor

`.clangd` reads `out/compile_commands.json`, generated by CMake with the
runtime's C++23 flags, dependency includes and build definitions. Configure
`out/` as described above before opening the project, including any compiler
or dependency overrides. Use `clangd` from the same LLVM installation as the
compiler.

From the repository root, refresh the compilation database and generated
headers with:

```sh
just runtime-editor
```

This builds the existing `cell-layout` target to generate `cell_layout.hpp`;
the other generated headers are refreshed during CMake configuration.

`.clangd-build.json` declares the same commands for Neovim configurations that
support Desktop's build-on-save integration. They run asynchronously on save
and use `out/` as the build directory. Other editors can invoke
`just runtime-editor` on save.

## Static analysis

Install `clang-tidy` and `run-clang-tidy` from the same LLVM installation as
the C++ compiler. From the repository root, run:

```sh
just runtime-lint
```

This refreshes `out/compile_commands.json` and generated headers, then analyzes
the runtime's production C++ sources with `.clang-tidy`. The runner looks beside
the configured compiler before searching PATH. It runs two processes by default;
`just runtime-lint 4` selects four.

The checks cover memory and resource errors, unsafe API use, dangling handles,
use after move and selected CERT rules. Files under `tests/` are excluded from
the runner and header diagnostics; `.clangd` also disables clang-tidy checks for
those files in the editor. Diagnostics include runtime headers and exclude
dependencies and generated headers. Warnings remain advisory during
the initial review; invalid configuration and compilation errors fail the command.
No fixes are applied.

## Components and dependency injection

| Component | Responsibility |
| --- | --- |
| `cli/` | Endpoint resolution, startup, stop, SSH bridge and agent hook commands. |
| `config/`, `lua/` | Bounded Lua VM, local modules, profiles and runtime configuration. |
| `metrics/` | Host counter projection and change revisions. |
| `memory/` | Allocator concepts, budgets, synchronization, owned objects and bounded containers. |
| `platform/` | Descriptors, PTYs, pipe processes, process identities, kqueue and workers. |
| `transport/` | Shared Desktop protocol framing, decoding and partial writes. |
| `terminal/` | Ghostty state, cell projection, acknowledged damage frames, text and search. |
| `model/` | Generational stores, panes, workspaces, attachments and retained client layouts. |
| `runtime/` | Service composition, request dispatch and event handling. |
| `runtime/delivery/` | Current-state selection, service projections, attachment rotation and write completion. |
| `agents/` | Provider identity, lifecycle transitions, screen evidence, progress and prompt budgets. |
| `execution/` | Pipe executions, bounded output retention and stdin state. |
| `graphics/` | Image projection, PNG decoding, transfers, shared-memory leases and credit. |
| `history/` | SQLite ownership, migrations, command persistence, imports and queries. |
| `workspaces/` | Typed background requests for root Git branch and dirty state. |
| `worktrees/` | Linked-worktree discovery and Git status/base-distance observation. |
| `paths/` | Bounded path indexes, filesystem/Git discovery, fuzzy ranking and highlights. |
| `editors/` | Existing Neovim, Vim and Emacs endpoint discovery and process validation. |
| `proxy/` | Host policy, authentication, port recovery, bounded resolution, CONNECT, relay, connection actor and child configuration. |
| `tls/` | Injected OpenSSL allocation, authority persistence, system roots, ALPN and verified two-sided TLS sessions. |
| `exchange_capture/` | Erased buffers, shared quotas, directional metadata, joining, publication and bounded content decoding. |
| `suggestions/` | A reusable Pi RPC process, bounded messages, deadlines and idle shutdown. |
| `diagnostics/` | Limit ledgers, Debug function tracing and bounded runtime telemetry. |

Components receive their allocator by reference. `Allocator`,
`ConcurrentAllocator`, `EventLoop`, `ProcessInspection`, `RequestService`,
`BackgroundExecutor` and `ObservationService` constrain template dependencies.
The composition root chooses concrete implementations; there is no virtual
service dispatch or runtime dependency container. Tests inject process
inspectors, services and allocators through the same interfaces.

The application allocation budget is 2 GiB. Owned containers, Ghostty, libpng,
SQLite and trace buffers use that allocator. Allocator callbacks at C library
boundaries are unavoidable ABI adapters. OS resources and libc/standard-library
internal allocations are outside the byte counter.

The runtime retains at most 256 panes, 32 clients, 64 workspaces, 64 tabs per
workspace and 64 attachments per client. Each request worker admits 32 jobs.
History, paths, editors and suggestions run on separate workers; Git observation
has its own single-job worker. Their queues and replies have explicit limits.

Each client can hold 64 tabs using inline storage. A held tab survives its last
terminal so Desktop can keep other applications' windows there, request an empty
snapshot and open another terminal. The last release or client disconnect removes
an empty tab; an explicit `CloseTab` still closes it. Holds are not restored from
a session checkpoint.

## Added protocol requests

| Family | Requests |
| --- | --- |
| Tabs | `HoldTab`. |
| Agents | `ReportAgent`, `ReportAgentSession`, `ReportAgentTitle`, `ReportAgentProgress`, `ReportAgentCommand`, `QueryAgents`, `AcknowledgeAgent`, `InterruptAgent`, `VerifyPaneDescent`. |
| Graphics | `ConfigureGraphics`, `GraphicsCredit`, `RequestGraphicsSnapshot`. |
| Worktrees | `RegisterWorktree`, `LaunchWorktree`, `ForgetWorktree`, `LaunchTab`. |
| Execution | `ExecutionRequest`, including start, status, input, EOF, cancel, forget and list. |
| Assistance | `FindPaths`, `OpenEditor`, `SuggestCommand`. |
| Diagnostics | `ReportLimit`, `QueryLimits`. |

Named agent reports require verified process descent, the original process
start identity and a matching foreground provider. Interruption uses the
provider's keys and Ghostty's keyboard encoder. Claude, Codex and Cursor need
idle-screen evidence before an interrupted turn settles. Focused panes and
blocked agents reject automated prompts; prompts between panes have a budget.

Agent command acknowledgement means that the bounded history queue accepted
the command, as in Zig. Those accepted writes survive client disconnects and
drain during orderly shutdown. Queries on the history worker observe preceding
writes. Persistence failures enter the runtime limit ledger. Acknowledgement
is not a promise of survival after abrupt process termination or power loss.

Worktree launches create background tabs. Git observation updates branch,
base, diff counts, commits ahead and lifecycle state without doing Git work on
the PTY event loop. Forgetting a worktree closes its tabs and removes its
runtime registration; it does not delete the checkout from disk.

Graphics support direct RGB, RGBA and PNG uploads, placement changes, deletion,
snapshots, inline chunks and shared-memory delivery to clients. Credit limits
outstanding transfers, and disconnects release their leases. Both screens retain at most 32 images and 128 placements each, with a
128 MiB default Ghostty byte limit per screen. Old images and offscreen
placements are evicted first; incomplete uploads have byte and chunk limits.
The transfer credit limit is 256 MiB per attachment and 512 MiB per client,
shared by that client's attachments. Frozen image copies independently reserve
the configured pane/global media budget and are prepared on the media worker.
Decoding now runs on a dedicated worker with two 64 KiB/64-event batches per
pane. A compile-time allocator dependency charges media allocations against
the configured pane/global budgets. The interactive terminal tracks image
cursor movement without decoding pixels. File input and child shared-memory
input pass exact byte/placement comparisons against Zig.

Suggestions are unavailable until an engine command is supplied. Each
`--engine-arg` adds one argument, including the executable. For a Pi RPC engine:

```sh
out/telar-runtime --socket "$runtime_directory/runtime.sock" --engine-arg pi --engine-arg --mode --engine-arg rpc
```

## Agent hooks

`hook claude|codex|pi|cursor|opencode [--socket PATH]` consumes the provider's
JSON from standard input. It connects to an existing runtime and verifies the
reporter's pane ancestry before sending progress, lifecycle, title and command
observations. Lifecycle failures leave the agent running and exit successfully.
Claude's worktree hooks also work outside a pane: creation returns the checkout
path, while removal retains a checkout with local changes. Their failures are
reported explicitly. This does not install provider integration files.

## Runtime telemetry

Debug builds emit one JSON sample per second to `<socket>.runtime-<pid>.log`.
Use `-DTELAR_RUNTIME_DIAGNOSTICS=ON` to enable the same counters in Release.
Default Release compiles out counters and sampling. Logs use `0600` permissions,
rotate at 4 MiB and retain one previous file. A bounded asynchronous writer
disables itself after an I/O failure; startup removes recognized orphan logs.

Samples cover runtime resources, input/PTY traffic, frames, allocator categories,
RSS, proxy/capture counters, history availability, queue occupancy and SQLite
write/query timing and failures. Completed media batches, graphics delivery,
process inspections, command capture and host sampling also contribute counters.
Detailed queue/storage gauges and marker/completion causes remain under review.
Telemetry contains numeric measurements, without
commands, prompts or terminal content. Function tracing is independent.

## Debug tracing

`TELAR_TRACE("component.function")` follows Desktop's scope-tracing interface
and Chrome trace format. This implementation supplies allocator-owned bounded
buffers and a writer thread without a Qt dependency. Trace records contain
literal scope names, timestamps and thread identities, not terminal content,
commands or prompts.

```sh
cmake -S . -B out-debug -G Ninja -DCMAKE_BUILD_TYPE=Debug -DGHOSTTY_VT_ROOT="$PWD/dependencies/install"
cmake --build out-debug
out-debug/telar-runtime --socket "$runtime_directory/debug.sock" --trace "$runtime_directory/runtime.trace.json"
```

Stop the daemon normally to flush the final batch. Open the JSON in Perfetto.
The file is created with `0600` permissions and must not already exist. Two
16,384-record buffers bound pending data; a slow writer drops records and
reports their count. Output is capped at 256 MiB. Release builds compile out
the scopes and reject `--trace`.

The instrumented flows cover event dispatch, PTY ingestion, terminal refresh,
frame encoding, graphics transfer, process authorization, history persistence,
path search, editor requests, suggestions and Git observation.

Trusted tap plugins add `plugins.submitExchange`, `plugins.processExchange`
and `plugins.workerExchange` to the runtime trace. Each isolated worker writes
`TRACE_PATH.tap-INDEX-ATTEMPT.json`, including `plugins.invokeExchange`.
Restart attempts use separate files. Debug shutdown gives the child up to
100 ms to finish its trace before terminating it; a stuck worker can leave an
incomplete trace. `tap-worker ENTRY --trace PATH` also supports direct host
diagnostics in Debug builds.

Set `TELAR_HOOK_TRACE` to a new output path for one Debug hook invocation to
trace input reading, report mapping, sending and worktree operations. The same
private-file and bounded-buffer rules apply. Release hooks ignore this variable.

## Validation

`runtime-tests` covers memory exhaustion and ownership, PTY errors and descriptor
isolation, terminal/frame behavior, graphics and credit, SQLite persistence,
execution state, agent authorization and interruption, worktree observation,
path ranking, editor validation and suggestion-engine failure modes. The Neovim
integration test runs when `nvim` is available. It checks a filename containing
spaces and a quote, cursor position, and rejection of a stale process identity.

`runtime-probe`, `history-probe`, `services-probe`, `agent-probe`,
`process-probe`, `reporter-probe`, `hook-probe`, `resume-probe` and
`graphics-probe` talk to actual daemon sockets. The agent fixture executes
inside a PTY and reports through an independently authenticated connection.
Comparison requires equivalent serialized results before considering timing.
Only nondeterministic identities, timestamps and explicitly documented fixture
paths are canonicalized. See [performance.md](performance.md) for workloads and
commands. `--enforce` requires at least six C++ wins in seven alternated pairs
for every selected workload.

For ASan and UBSan, configure a separate Debug build with
`-DTELAR_RUNTIME_SANITIZERS=ON`. This instruments C++ code; the independently
built Ghostty and system libraries are not instrumented by that option.
Run performance comparisons without concurrent builds or sanitizer binaries.

`tools/check_desktop_launch.py` uses `desktop-launch-probe`, compiled from
Desktop's actual endpoint and login-shell sources. It checks adjacent, bundle
and PATH layouts, paths containing spaces, automatic startup, reuse, socket
permissions, wire handshake and shutdown. An invalid PATH fallback ensures
the adjacent and bundle cases really use their installed command.

## Compatibility limits

All 62 request tags are handled. Replacement acceptance remains open for the
contracts below; the detailed evidence is in [parity.md](parity.md).

- Client delivery now bounds pending responses at 128, reserves notification
  confirmations before publication and follows Zig's delivery priorities.
  Optional notifications drop under pressure; lost tab closures request resync.
  The queue has an exact reference oracle. Late-bound pane/workspace/limit
  reads, current-state coalescing and shared attachment rotation are covered by
  blocked-client fixtures against Zig. Exit releases its attachment after the
  socket write completes. Broader lifecycle/resource coverage remains.
- Debug diagnostics include command capture, VT storage, media allocations,
  graphics storage, transfer staging/adoption and client response queue depth,
  high-water marks and drops.
- Provider screen scanners, integration installation and system-trust command
  behavior have reference oracles. Actual system-keychain changes and native
  macOS Spaces transitions have not been exercised. Broader concurrent
  lifecycle and resource-boundary acceptance remains open.
- Whole-runtime performance is not accepted. Atomic file/shared graphics,
  small Brotli capture and other gates recorded in [performance.md](performance.md)
  still fail. Paired results apply to the recorded binaries and workloads on
  macOS ARM64; they are not a universal performance guarantee.

Graphics placement eviction follows the reference's offscreen-first and
oldest-image policy. Temporary-file Kitty input remains disabled, as in Zig.
Plugin completeness has low priority. Packaging, hosted CI and release work
are deferred at the user's request.


The runtime also accepts `server endpoint`, `server stop`, `server bridge`,
`--background` and `--fresh`. Endpoint discovery starts the same C++ executable
when needed. `--fresh` preserves the checkpoint as `.previous` after acquiring
the listener. Configuration uses the vendored Lua 5.5.1 sources compiled directly
with C++, without linking Telar Zig modules. The C++ exception mode preserves
callback cleanup on Lua failures. Its allocator is injected and its default
budgets are 16 MiB, one million instructions and two seconds.


Process identification includes bounded group-member selection and cached
acquisition. Hook descent checks run on a separate worker. Conflicting named
reports wait for process reidentification while their connection is paused;
other clients continue. Payload ownership, ordering, original observation times,
rejection caching and stale-generation handling have focused tests. See
[parity.md](parity.md) for the cross-runtime replacement fixtures and remaining
acceptance gaps.


Path indexing publishes partial results while its build worker runs. Four clients
can own independent indexes with 512K entries and 32 MiB of path bytes each.
Queries retain only the published prefix; refresh, root replacement and disconnect
cancel a build before its storage is reused. Small completed indexes retain the
bounded inline query path. `PathSearchIndex` allows compile-time injection for
controlled scheduling tests.
