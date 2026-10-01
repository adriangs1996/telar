# Fleet operations verification

Acceptance runs on macOS arm64 in this task checkout, using disposable source and
destination homes, runtimes and fake SSH. The stub accepts only `fixture@fake`
and executes locally; it cannot select a real fleet destination. The synthetic
agent checks `--no-daemon`, consumes the transferred brief and creates a Git
commit without inference. Teardown stops only the fixture runtimes, waits for
their socket removal, accounts for any remaining process naming the exact
fixture root, and deletes their temporary directories.

## Reproduction

Use Zig 0.16.0, as required by `build.zig.zon`, and build with `-j2`:

```sh
zig build install headless -Dgui=false -j2
zig build test-schema test-fuzz-ipc-client test-fuzz-ipc-server test-cli test-runtime test-client test-headless check-library-reexports codestyle -Dgui=false -j2 --summary all
zig test -lc --dep privatefile -Mroot=lib/localsocket/root.zig -Mprivatefile=lib/privatefile/root.zig
zig test -lc lib/privatefile/root.zig
python3 tools/test_fleet_operations.py -v
python3 tools/test_machine_setup.py
python3 tools/remote_login_smoke.py
```

On this host, Homebrew's Zig/libc++ and the default newer Apple SDK failed the
baseline build. Verification uses a disposable official Zig 0.16.0 archive,
SHA256 `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489`,
checked against `https://ziglang.org/download/index.json`. A task-local libc
configuration selects the installed MacOSX15.4 SDK; pass it using `--libc`.
No product source workaround, global compiler installation change or default
SDK change is used for these toolchain failures.

The 19 fleet acceptance tests and both remote-login smoke cases pass. The native
socket suite passes 23 tests, including the bind-before-listen startup race and
unsafe startup-lock refusal. The private-file suite passes all 11 tests.
The broad check passes 1,680 tests, including the exact-schema corpus, both
IPC fuzz seed suites, CLI, runtime, shared client and headless client. The
model/client boundary checks and library re-export checks pass. Codestyle passes.
The supplied setup fix is imported as `88fc9076` and its 16 isolated setup tests
pass. These are actual local checks, not the coordinator's reported results.

The full graphical build was also attempted. Its unchanged syntax-highlighter
Rust dependency requires Rust 1.90 (`tree-sitter-language 0.1.8`); the installed
stable compiler is 1.88.0 and installed nightly is older. That build cannot
complete with these installed tools. The runtime/CLI and headless builds are
complete; GUI rendering and Linux execution are not claimed as tested here.

## Invariant evidence

| Contract | Evidence |
| --- | --- |
| Raw binary streams, literal argv, exact status, no repository/window | Fake-SSH raw execution acceptance, including NUL/non-UTF8 stdout and independent stderr |
| Runtime ownership, identity and client death | Detached/replayed ID, identity-conflict refusal including control-byte field boundaries, disconnect EOF, retained result after workspace removal |
| Timeout differs from cancellation | Timed-out sleep continues; explicit cancel kills only its chosen process group |
| Bounded pressure/retention | Two MiB output exceeds the one MiB tail with explicit cursor loss; full stdin queue still allows timeout; retained IDs can be listed/forgotten; 32 retained executions refuse a 33rd |
| Administration ownership | A user workspace named Administration is neither adopted nor removed; explicit workspace cwd remains authoritative |
| Child failure and teardown | Missing executable has a failed result; orderly runtime shutdown terminates and reaps its owned child |
| Schema compatibility | Integrated generation 85, golden fingerprint `64d3c4`, decoder/encoder round trips and malformed/boundary inputs; existing handshake mismatch tests |
| Missing/recorded/existing/ambiguous clones | Automatic create with no clone; explicit prepare; closed-workspace discovery; two clones require selection; unrelated paths survive refusal |
| Concurrent/interrupted preparation | Two cold-start callers leave one runtime and publish/reuse one clone; truncated bundle publishes nothing; owned stages recover; unowned stages remain untouched; symlink locks and shared writable clones are refused |
| Git safety/readiness | Sanitized credential-bearing source origin, dirty-file report, no provider credential copy, non-force divergence refusal, explicit shallow/partial/submodule/LFS refusal |
| Setup authorization and truthfulness | Unapproved declaration and failing private-dependency fixture start no agent; success, explicit retry and cancellation are observed executions |
| File safety | Atomic binary round trip, no overwrite, EOF length mismatch, symlink traversal, FIFO, hardlink, path traversal and oversized input refusal |
| Cross-machine lifecycle | Prepare, setup, brief, simulated Codex, commit, fetch, merge in disposable clone, and public worktree removal |

Process lifetime and I/O ownership are also explicit in
[execution](../flows/execution.md): workers own handles, the event loop only
tries the transport mutex, storage outlives joined workers, and output has bounded
queues independent of PTY traffic. Concurrent preparation also passes 20 consecutive repetitions, each with new
source/destination directories and runtimes. No real provider authentication, package login,
fleet connection, installation, deployment or user-global skill edit is part of
these checks.

## Coordinator's personal skill

No personal skill is modified. When integrating this branch, update the existing
personal dispatch skill from `src/cli/skill/coordinator.md`, specifically its
“Prepare and send inputs” section and its Codex `--no-daemon` instruction. With a
matching built binary, `telar --skill coordinator` prints that exact shipped text.
Keep any existing personal machine/model/approval constraints. Replace obsolete
instructions requiring an already-open destination clone or manual SSH copying;
use the public repository, execution, setup and file operations shown there.

## Coordinator integration verification

The combined fleet and global-sidebar branch also builds the GUI in ReleaseFast
on the coordinator. Its schema is generation 85 with fingerprint `64d3c4`.
The integration check passes 2,280 schema, IPC fuzz, runtime, CLI, shared-client,
GUI and headless tests; the added maximum-dispatch-argv case passes with the CLI
suite. The 19 fleet acceptance cases also pass here, including setup and exact
coordinator attribution in one remote dispatch. The local runtime smoke verifies
automatic coordinator capture and checkpoint restoration. Socket and private-file
suites pass 23 and 11 tests respectively. Original remote-host toolchain notes
above describe that host, not a limitation of the integrated build.
The 16 isolated setup tests and both remote-login smoke cases pass on the
coordinator too. The personal dispatch skill now routes remote briefs, setup
and follow-ups through its fleet instructions while retaining its provider,
focused-pane and authorization constraints.
