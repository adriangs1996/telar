# Remote attach

`telar gui --remote <ssh-destination>` (and `telar --remote`, which opens the
same window) runs a client against the runtime on another machine. The
remote transport is the local transport: the same framing, schema handshake,
bounds and backpressure travel through one OpenSSH Unix-socket forward, so the
runtime cannot tell a forwarded client from a local one.

The window keeps its own client for this machine and opens the remote one
beside it, in its own machine slot, and shows it first
([machine presentation](machine-presentation.md)). The window opens first and
connects on a worker, and a lost connection does not close it:
[runtime link](runtime-link.md) covers connecting, reconnecting and what the
window shows meanwhile. `telar-headless --remote` attaches its one client to
the remote runtime the same way ([headless client](headless-client.md)).

## End-to-end path

```text
telar gui --remote dev@box
        |
client.runNative -> gui.run            the window opens; its own client is local
        |
window_machines.open                   a saved row by destination or label, or
        |                              a temporary row never written back;
        |                              openClient, then select
        |
runtime_link.start -> machine_connection.connect (connection job)
        |
remote.establish
        |
ssh -T <managed options> dev@box 'printf ... "$HOME" "${SHELL:-/bin/sh}"; exec telar server endpoint'
        |     BatchMode, keepalives, no agent forwarding, the destination's
        |     control master; 30 s timeout; discovers remote home, shell and
        |     socket; starts the remote runtime if needed
        |
ssh -T <forward options> -L <local>/remote-<hash>-<slot>.sock:<remote>.sock dev@box 'cat >/dev/null'
        |     StreamLocalBindUnlink, ExitOnForwardFailure, ControlPath=none;
        |     stdin is a pipe only this process holds
        |
local managed 0700 directory holds the forwarded socket
        |
remote.connectForwarded (bounded retries) + schema handshake
        |
the machine's client runs unchanged; shared-memory graphics are disabled, so
the runtime delivers image chunks instead of /dev/shm names
```

## Ownership

The forward is a child process owned by the client; exiting the client kills
it and removes the forwarded socket file. If the client dies without that,
the pipe on the forward's stdin closes, the remote `cat` ends and ssh exits,
so a crashed window leaves no forward behind. The forward never joins the
control master: a forward the master owned would outlive the `ssh` that
asked for it. The forwarded path carries a hash of the destination and the
window slot, so two remotes never collide, two windows on one machine never
share or remove each other's socket, and a window reconnecting reuses its
name. A window's client identity mixes its slot with the destination, so the
runtime keeps one layout per window and machine. Discovery requires `telar` on the remote PATH for
non-interactive SSH. Discovery accepts exactly three bounded absolute paths
and rejects control bytes, extra output and socket paths containing `:`. SSH
destinations cannot start with an option or contain whitespace/control bytes.

Initial launches use the remote home and login shell, not the client's current
directory or `$SHELL`. An explicit command still selects the remote program to
run. Reattaching to an existing pane preserves that pane's process and cwd.

A remote machine's client never starts a runtime locally, and
`--config`/`--profile` affect only the local client: the remote runtime reads
its own configuration.

## Validation

- `src/core/ssh_destination.zig` tests destination validation and hashing.
- `src/client/machines/remote_discovery.zig` tests bounded discovery and malformed paths.
- `src/gui/run.zig` tests that one window slot gets a distinct identity on each machine.
- `src/cli/client.zig` tests remote launch defaults and explicit commands.
- `telar server endpoint` is covered by the parser tests and prints through
  the same connector the client uses.
- `python3 tools/remote_smoke.py --destination dev@box` drives
  `telar-headless --remote` and checks remote home,
  OS, UID, shell PID and an exported variable across detach/reconnect. It needs
  a fresh remote workspace, refuses to type into unknown panes and leaves its
  own shell running. Results go to `.zig-out/remote-smoke/result.json`.
- A manual macOS-to-Arch-ARM test through OpenSSH retained the same Linux shell
  PID and an exported variable after detach and reconnect.
- The same probe passed from macOS UID 501 to Debian 13 UID 1000 in Docker.
  Recreating that container retained the history database and checkpoint in a
  named volume, but the old shell process was replaced.

## SSH requirements

Install matching Telar builds on both machines and make the Linux binary
available on the non-interactive SSH PATH. Authenticate with a key and verify
the host key before connecting:

```sh
ssh dev@box 'command -v telar; telar --version'
./zig-out/bin/telar gui --no-config --remote dev@box
```

The SSH server must support Unix-socket forwarding and connect to the runtime
as the authenticated user. OrbStack's built-in SSH forwarded our probe as UID
0 rather than UID 501, so Telar correctly rejected it. The local VM setup uses
an OpenSSH daemon inside Linux instead. Do not weaken peer-UID checks to work
around an SSH server's behavior.
