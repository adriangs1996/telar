# Remote attach

`telar gui --remote <ssh-destination>` (and `telar --remote`, which opens the
same window) runs a client against the runtime on another machine. The
remote transport is the local transport: the same framing, schema handshake,
bounds and backpressure travel through one SSH session whose remote end
relays bytes to the runtime's Unix socket unchanged, so the runtime cannot
tell a remote client from a local one.

The window keeps its own client for this machine and opens the remote one
beside it, in its own machine slot, and shows it first
([machine presentation](machine-presentation.md)). The window opens first and
connects on a worker, and a lost connection does not close it:
[runtime link](runtime-link.md) covers connecting, reconnecting, failing and
what the window shows meanwhile. `telar-headless --remote` attaches its one
client to the remote runtime the same way ([headless client](headless-client.md)).

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
remote.connect
        |
ssh -T <managed options> dev@box '/bin/sh -c ... exec telar server endpoint'
        |     BatchMode, keepalives, no agent forwarding, the destination's
        |     control master; 30 s timeout. Prints the remote home, shell,
        |     runtime socket and wire schema; starts the remote runtime if
        |     needed. Another schema stops here.
        |
localsocket.pair                       two connected sockets, close-on-exec
        |
ssh -T <managed options> dev@box 'exec telar server bridge'
        |     stdin and stdout: one end of the pair; stderr: a pipe read
        |     only after a failure. Same control master: no new connection
        |     or authentication.
        |
telar server bridge (on dev@box)       connects to the runtime socket and
        |                              copies bytes both ways, one thread per
        |                              direction; exits when either side ends
        |
RuntimeConnector.negotiate             schema handshake over the other end
        |
the machine's client runs unchanged; shared-memory graphics are disabled, so
the runtime delivers image chunks instead of /dev/shm names
```

## Ownership

The bridge session is a child process owned by the client (`Forward`);
stopping it kills that `ssh`, the control master closes the session, and
the remote bridge reads the end of its input and exits. If the client dies
without stopping it, its end of the pair closes and the same happens, so a
crashed window leaves nothing behind. No socket file exists on the local
machine, so two windows, a headless client and a window, or two profiles
never share or remove each other's connection.

Every call to one destination shares its control master
(`src/client/machines/SshOptions.zig`): discovery, each window's bridge,
`telar machine check`, `telar --machine` dispatch and Git transfers. The
first one authenticates; the rest reuse that connection while it lives
(`ControlPersist=600`). An `ssh -L` forward cannot share it: OpenSSH hands
a forward asked for through a master to the master, where it outlives the
`ssh` that asked for it. With the macOS OpenSSH 10.3p1 client against the
Debian test box, a socket forwarded through the master still accepted
connections after the `ssh` that asked for it was killed with SIGKILL,
while a stdio session through the same master ended its remote command
when its `ssh` died.

A window's client identity mixes its window identity with the destination,
so the runtime keeps one layout per window and machine. Discovery and the
bridge run the profile's `telar_path` when it has one
([machine profiles](machine-profiles.md#the-file)) and otherwise require
`telar` on the remote PATH for non-interactive SSH, the same
build on both machines (discovery compares the schema), and accept exactly
three bounded absolute paths and the schema, rejecting control bytes, extra
output and socket paths containing `:`. SSH destinations cannot start with
an option or contain whitespace/control bytes.

Initial launches use the remote home and login shell, not the client's current
directory or `$SHELL`. Supported shells (bash, zsh, ksh, sh, dash and fish)
start with `-l -i`, following the shell's login and interactive startup rules.
Other shells start directly, without flags telar does not know. An explicit
command keeps its arguments unchanged and selects the remote program to run.
Reattaching to an existing pane preserves that pane's process and cwd.

A remote machine's client never starts a runtime locally, and
`--config`/`--profile` affect only the local client: the remote runtime reads
its own configuration.

## Failures

`remote.sshFailure` reads a failed call's exit status and error output.
OpenSSH exits 255 for its own failures; `Host key verification failed` or a
changed host key, and `Permission denied (…)`, are permanent. A remote shell
exits 127 or 126 when it cannot find or run `telar`. Discovery output this
telar cannot read, another schema, and `telar protocol mismatch` (the remote
runtime is another build) are permanent too. The link stays failed with that
text until the person retries ([runtime link](runtime-link.md)). Anything
else, such as a refused or timed-out connection, is retried with backoff.
When the bridge session fails, what `ssh` printed on standard error so far
becomes the link's failure text.

## Validation

- `src/core/ssh_destination.zig` tests destination validation and hashing.
- `src/client/machines/remote_discovery.zig` tests bounded discovery, the
  schema line and malformed output.
- `src/client/machines/remote.zig` tests which SSH failures are permanent.
- `lib/localsocket/pair.zig` tests the pair and its close-on-exec flag;
  `src/cli/runtime_bridge.zig` tests that the relay copies frames unchanged.
- Against two Debian boxes built from this tree: two windows, each with
  this machine and both boxes, then `telar-headless --remote` to one box,
  gave each client its own id on each runtime; the boxes logged no new SSH
  login during the run, every window and the headless client riding the
  control master an earlier check had opened; no socket file appeared in the local runtime
  directory; closing the headless client left both windows attached, and
  closing the windows left no `telar server bridge` on the box.
- `src/gui/run.zig` tests that one window slot gets a distinct identity on each machine.
- `src/client/connection/runtime_link.zig` tests supported and unsupported
  remote default shells, owned arguments across discovery replacement,
  explicit commands and unchanged local defaults.
- `python3 tools/remote_login_smoke.py` runs discovery and the bridge through
  a local SSH stub against a disposable runtime, with synthetic `.zprofile`
  and `.zshrc` files. It checks login environment before interactive startup,
  remote home, retained shell PID/state after reconnect and literal arguments
  of explicit commands. It requires zsh and built `telar`/`telar-headless`
  binaries, and makes no network connection.
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

`telar machine setup box` does all of this for a saved machine
([machine setup](machine-setup.md)): it installs this build under the
remote home, saves its path so the remote PATH no longer matters, and
refuses to go on until batch-mode SSH works. By hand: install matching Telar
builds on both machines and make the Linux binary available on the
non-interactive SSH PATH. Authenticate with a key and verify the host key
before connecting:

```sh
ssh dev@box 'command -v telar; telar --version'
./zig-out/bin/telar gui --no-config --remote dev@box
```

The runtime checks that its peer is the same user; over SSH that peer is
the bridge, which runs as the authenticated user. Do not weaken peer-UID
checks to work around an SSH server's behavior.
