# Remote attach

`telar --remote <ssh-destination>` runs the local client against the runtime
on another machine. The remote transport is the local transport: the same
framing, schema handshake, bounds and backpressure travel through one
OpenSSH Unix-socket forward, so the runtime cannot tell a forwarded client
from a local one.

## End-to-end path

```text
telar --remote dev@box
        |
ssh dev@box telar server endpoint      (BatchMode, 30 s timeout)
        |     starts the remote runtime if needed, prints its socket path
        |
ssh -N -L <local>/remote-<hash>.sock:<remote>.sock dev@box
        |     StreamLocalBindUnlink, ExitOnForwardFailure; child kept until exit
        |
local managed 0700 directory holds the forwarded socket
        |
normal client connect (bounded retries) + schema handshake
        |
frontend client runs unchanged; shared-memory graphics are disabled, so the
runtime delivers image chunks instead of /dev/shm names
```

## Ownership

The forward is a child process owned by the client; exiting the client kills
it and removes the forwarded socket file. The forwarded path is derived from
a hash of the destination, so two remotes never collide and reconnecting
reuses the same name. Discovery requires `telar` on the remote PATH for
non-interactive SSH; the printed endpoint must be one absolute path.

The client never starts a runtime locally in remote mode, and
`--config`/`--profile` affect only the local client: the remote runtime reads
its own configuration.

## Proof

- `src/cli/remote.zig` proves destination hashing; establishment is exercised
  manually because it needs a reachable SSH host.
- `telar server endpoint` is covered by the parser tests and prints through
  the same connector the client uses.
