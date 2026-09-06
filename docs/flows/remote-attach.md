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
ssh -T dev@box 'printf ... "$HOME" "${SHELL:-/bin/sh}"; exec telar server endpoint'
        |     BatchMode, 30 s timeout; discovers remote home, shell and socket
        |     starts the remote runtime if needed
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
non-interactive SSH. Discovery accepts exactly three bounded absolute paths
and rejects control bytes, extra output and socket paths containing `:`. SSH
destinations cannot start with an option or contain whitespace/control bytes.

Initial launches use the remote home and login shell, not the client's current
directory or `$SHELL`. An explicit command still selects the remote program to
run. Reattaching to an existing pane preserves that pane's process and cwd.

The client never starts a runtime locally in remote mode, and
`--config`/`--profile` affect only the local client: the remote runtime reads
its own configuration.

## Proof

- `src/cli/remote.zig` tests destination validation and hashing.
- `src/cli/remote_discovery.zig` tests bounded discovery and malformed paths.
- `src/cli/client.zig` tests remote launch defaults and explicit commands.
- `telar server endpoint` is covered by the parser tests and prints through
  the same connector the client uses.
- `python3 tools/remote_smoke.py --destination dev@box` checks remote home,
  OS, UID, shell PID and an exported variable across detach/reconnect. It needs
  a fresh remote workspace, refuses to type into unknown panes and leaves its
  own shell running. Results go to `.zig-out/remote-smoke/result.json`.
- A manual macOS-to-Arch-ARM test through OpenSSH retained the same Linux shell
  PID and an exported variable after detach and reconnect.
- The same probe passed from macOS UID 501 to Debian 13 UID 1000 in Docker.
  The Linux client also attached and detached through an SSH PTY. Recreating
  that container retained the history database and checkpoint in a named volume,
  but the old shell process was replaced.

## SSH requirements

Install matching Telar builds on both machines and make the Linux binary
available on the non-interactive SSH PATH. Authenticate with a key and verify
the host key before connecting:

```sh
ssh dev@box 'command -v telar; telar --version'
./zig-out/bin/telar --no-config --remote dev@box
```

The SSH server must support Unix-socket forwarding and connect to the runtime
as the authenticated user. OrbStack's built-in SSH forwarded our probe as UID
0 rather than UID 501, so Telar correctly rejected it. The local VM setup uses
an OpenSSH daemon inside Linux instead. Do not weaken peer-UID checks to work
around an SSH server's behavior.
