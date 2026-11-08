# Execution and runtime CLI contracts

The nine families below implement 25 commands.

## Interfaces for the other CLI packages

`file put ABS --bytes N` reads raw stdin and returns
`{"bytes":N,"published":true}\n`. `file get ABS` writes only the file's bytes.
Both execute on the machine where that CLI runs, without contacting a runtime.
Neither accepts `--socket` or `--json`. A put consumes input through EOF, checks
the exact count and the 128 MiB bound, syncs an owner-only temporary file and
publishes without replacing a destination. Gets reject symlinks, hard links,
nonregular files and foreign ownership. Ancestors are opened with directory
descriptors and no symlink following; the final parent must belong to the user
and have no group/other write permission.

A machine transport can therefore forward literal words such as
`exec -- REMOTE_TELAR file put ABS --bytes N`, with the binary input unchanged.
The remote program comes from the machine profile; never hardcode a local
installation path. Get stdout must remain raw throughout dispatch.

`repository receive --identity HOST/PATH --transport URL --commit HASH
--ref refs/telar/transfer/NAME --bytes N [--workspace PATH|ID]` is the hidden
receiver. It consumes one bounded bundle through stdin. Its JSON reports
`path`, `commit`, `repository`, `repository_ready`, `reused`, `environment`.
The receiver checks the identity/transport and fetched commit, locks the managed
repository, verifies the bundle, and refuses shallow/partial/LFS/submodule
repositories. Existing branches and checkouts stay intact. New clones are
published exclusively under `$XDG_DATA_HOME/telar/repositories/SHA256(identity)`.
Discovery uses the live catalog, closed workspace paths in the history database,
and the managed path; an ambiguous identity requires `--workspace`.

`repository::prepare(memory, options, remote_program, capture)` is the source
interface in `repository_prepare.hpp`. The callback receives a span of literal
words beginning `exec -- REMOTE_TELAR repository receive ...` and a borrowed,
rewound, readable bundle descriptor. It returns the receiver's stdout as an owned
string; it must preserve stderr and must neither close the borrowed descriptor
nor silently fall back to another machine. Preparation resolves a committed ref,
reports omitted dirty files, creates a bounded bundle, verifies the receiver's
JSON and removes its temporary ref/directory on success or failure.

The public `repository prepare --machine LABEL ...` currently resolves the
profile by running this C++ CLI's `machine list --json`, and captures the bundle
through this CLI's `--machine LABEL ...`. Package 5 must provide those public
entry points. Until integrated, this branch reports `MachineDispatchUnavailable`.
The generic preparation interface and the local `exec`/receive pipeline are
tested by `repository-prepare-probe`; real SSH preparation remains unverified.

`project_setup::prepare(memory, cwd, authorized, detach, socket)` returns an
optional execution ID. No declaration returns null without starting a runtime;
an existing declaration with `authorized == false` is refused. `worktree create`
can pass its explicit `--setup` authorization and socket through this interface.
The public `project setup` command always authorizes the recipe, prints its ID
on stderr, and either detaches or waits up to 600 seconds, forwarding both child
streams to stderr. Every invocation repeats the recipe. Its CLI grammar has no
socket argument, so isolated tests explicitly set `TELAR_SOCKET` to their own
socket, including in the server's environment for nested executions.

## Native schema

`api schema` derives the handshake identifier from `handshake::schema_id`:
`schema_version` is `cqp00001`; `fingerprint` is the hexadecimal encoding of those
eight bytes, `6371703030303031`. It describes the actual C++ tag enums, including
the three native clipboard requests and three clipboard server messages. Tag
tables are checked against the C++ declarations by CTest. `runtime status`
reports the same native identifier.

No GUI change is needed by these families. Linux-specific publication and
dynamic-library paths have not been executed in this macOS validation.

## Regression checks

`exec-runtime-offline-tests` preserves parsing, binary file transfer, safe logs,
schema metadata and deterministic observer outputs without a runtime.
`exec-runtime-cli-tests` runs real executions, imports, prune confirmations,
recipes, bundle reception, closed-workspace discovery and the preparation probe.
`runtime-tests` needs a descriptor limit above 4096 for its `F_DUPFD(4096)`
check; raise the soft limit (for example `ulimit -n 8192`) before running it.

Common changes are `ControlFailure::message()` (owned raw refusal text), the
optional request-buffer capacity of `ControlSession`, standard-allocator support
in `appendJsonText`, command I/O/limit helpers, the Git observation policy moved
to `dlls/telar-platform`, and `CommandOutput::runWithInputDiagnostics`. Repository
discovery loads system SQLite only when needed, through its read-only API; the
CLI neither links SQLite nor requires its headers, and hook startup loads the
same libraries as the baseline.

`tools/measure_exec_runtime_hook.py` compares frozen before/after binaries using
seven alternating pairs of sixteen Claude SessionStart events, checking all
stdout/stderr and IPC frames. The first two runs measured baseline/new p50
5.150/5.290 ms and 5.191/5.404 ms, with median pair ratios 1.050 and 1.030.
These are measured increases; their cause is not established. `runHook` has 525
instructions in both binaries; the inspected differences are addresses of the
stack guard, stderr, a diagnostic literal and call targets. This alone does not
prove the cause of the process-startup difference. A smaller formatting
experiment preserved all 141 exact cases but improved only 4/7 hook pairs
(median ratio 0.984), so it was rejected and removed.

The final binary was measured again after the recipe EOF validation change:
baseline/new p50 5.768/5.935 ms, median pair ratio 1.026, 1/7 wins. The hook latency gate remains open; this port does not claim zero startup regression.
