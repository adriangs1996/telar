# Runtime-owned execution

`telar [--machine LABEL] exec -- PROGRAM ARGUMENTS...` runs literal argv with
independent byte streams. It needs neither Git nor a window. A shell is explicit:
`exec -- /bin/sh -c 'printf hello'`. For a terminal, use the existing
`workspace create --directory PATH -- COMMAND...` or `worktree exec`; terminal
screen text is not a file transport and does not preserve independent stderr.

The runtime owns an `Executions` table and a pipe worker per active row. The
client only waits and copies bytes. `--cwd ABS` overrides the destination cwd;
`--workspace ID` refers to that destination's runtime. Otherwise the runtime
lazily creates its own Administration workspace at destination HOME. Its ownership
is an explicit model ID, never its display name. No keeper shell is spawned.
The runtime removes its empty administration workspace after its final execution
finishes, unless someone has added real panes. Results remain in the executions
table independently. An explicitly supplied workspace is never removed by exec.

```sh
telar --machine box exec --no-stdin -- /usr/bin/uname -a
telar --machine box exec --id 829341 --detach --json -- /bin/sh -c 'sleep 30; echo done'
telar --machine box exec list --json
telar --machine box exec status 829341
telar --machine box exec output 829341
telar --machine box exec cancel 829341
telar --machine box exec forget 829341
```

`--id` accepts a caller-selected nonzero 64-bit ID; absent one, the CLI generates
one. Retrying a start with the same ID and launch parameters finds the same row;
different parameters are refused. A transport failure never automatically repeats
a launch. The CLI prints the ID on an uncertain launch failure so the caller can
query before retrying. Forgetting a completed result deliberately releases that
ID and its storage. Results are not silently evicted. `exec list --json` lists
retained IDs, workspace IDs, state and exit codes, including foreground commands
whose streams carried no metadata. List walks IDs in ascending order; concurrent
creation/removal can change the listing. Query each ID for stream counters and
failure details, and forget completed results to release capacity.

Foreground output contains only child bytes. Exit status is the child status,
including `128 + signal`; transport/observation failure is 125. `--timeout S`
returns 124 and leaves work running. These codes can also be genuine child codes;
query status to distinguish. Detached start, status, cancel and forget return JSON.
`output` reads a snapshot from independent `--stdout-offset` and `--stderr-offset`
cursors. It does not change another reader's position. `cancel` requests SIGKILL
of only this execution's owned process group; query status for its final result.
Descendants that deliberately escape that group are outside this ownership
contract. Work survives client/SSH death, not runtime death or host restart.
There is no checkpoint/replay of executions or integration into PTY history.

Stdin belongs to the launching connection. EOF, `--no-stdin`, detach or a dropped
connection closes it after accepted queued bytes drain. Reconnection is for
observation/cancellation, not a new stdin producer. A child that closes its input
is reported closed. Input is acknowledged with byte offsets; a retry cannot
append an acknowledged chunk twice. Timeout and disconnect never mean cancel.

Bounds are 32 retained executions, 64 argv entries, 32 KiB of argument bytes, 4 KiB of cwd,
4 KiB per stream per reply, a 64 KiB stdin queue, and the newest 1 MiB per output
stream. An exhausted execution table refuses new starts until `forget`. Pipe
workers drain even when nobody reads; excess old output is dropped. A reader
whose cursor has fallen behind receives the retained start and total counters,
a named limit notice, and a nonzero CLI result. Resume explicitly at the reported
cursors. For important larger artifacts, write a destination file and retrieve it
with `telar --machine LABEL file get ABS_PATH`; a stopped observer cannot recover evicted
bytes. `file get` through exec likewise reports loss if its consumer falls behind.

Pipe I/O, child spawning, waiting and environment copying run off the runtime
loop. Each worker owns its process handles. It holds a short transport mutex only
for bounded buffer copies; the runtime uses tryLock and returns `ExecutionBusy`,
which the CLI retries. Stdin queue capacity is advertised before the CLI reads.
The event loop never waits for a pipe or a slow consumer. Completion joins the
worker before storage can be forgotten. Runtime teardown cancels and joins all
workers before releasing buffers. The root PID stays unreaped until both output
pipes close, preventing PID reuse during group cancellation. Client responses use
the existing bounded delivery queues. Launch allocation is control-plane work;
interactive PTY/frame paths do not touch these buffers.

Execution requests/replies use the exact-schema handshake, golden corpus and
client/server fuzz seeds. Mismatched versions are refused before any launch.
See `tools/test_fleet_operations.py` for binary output, literal argv, disconnect,
EOF, timeout, cancellation ownership, replay, bounded output and workspace tests.
EOF and runtime shutdown operate through the same atomic flags and worker join
path as cancellation; no callback retains a removed table row.

Concurrent cold starts serialize endpoint stale probing, binding and listening
under an owned `runtime.sock.lock` file. A socket that has just been bound cannot
be mistaken for an abandoned endpoint before its creator starts listening. A
losing runtime sees the live endpoint and exits. The startup lock is released
before runtime event processing and never serializes interactive traffic. Native
socket tests cover this window and refuse a symlink substituted for the lock.
