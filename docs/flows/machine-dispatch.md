# Machine dispatch

`telar --machine LABEL COMMAND…` runs one telar command on a saved machine and
returns its output and exit status. A coordinator in one pane uses it to reach
every machine the same way.

## End-to-end path

```text
telar --machine box pane list --json
        |
MachineDispatchOptions.parse          flag first in argv, never from the environment
        |
main.dispatchToMachine                refuses a command that opens a window
        |                             or names another machine
machine_dispatch.resolve              a saved profile first, then the local label
        |
   local ──> main.dispatch(argv)      the command runs here, as typed
        |
  remote ──> machine_dispatch.forward
        |      ssh -T <SshOptions> -- dev@box telar dispatch-argv aX aY …
        |      stdin, stdout and stderr pass through; the exit status returns
        v
telar dispatch-argv (on box)
        |
machine_dispatch.decode -> main.dispatch(argv)
```

## Why the argv is encoded

OpenSSH joins the remote command into one string for the remote login shell,
which can be sh, bash, zsh or fish, each with its own quoting rules. Quoting
for one of them is wrong for another. Each argument therefore travels as `a`
followed by its unpadded base64url form (`src/cli/dispatch_argv.zig`): only
letters, digits, `-` and `_`, which no shell treats as syntax, and never an
empty word. The remote side refuses anything else and any decoded NUL byte.
The command runs the profile's `telar_path` when it has one, and otherwise
needs `telar` on the remote non-interactive PATH, as remote attach does.

## SSH

`src/client/machines/SshOptions.zig` builds the options every managed call passes:
`BatchMode=yes`, keepalives, `ForwardAgent=no`, and a control master per
destination in telar's owner-only runtime directory with `ControlPersist=600`.
The first call authenticates; later discovery, dispatch, checks and every
window's bridge session reuse that connection while it lives, and an idle
master stays ten minutes after its last session
([remote attach](remote-attach.md#ownership)).

## Rules

- `--machine` is read only from argv, so a pane never passes its machine to a
  child process.
- A failure on the machine is a failure. Nothing falls back to the local
  machine; `ssh`'s own failures exit 255.
- Without a subcommand, or with window options or `gui`, `telar --machine
  LABEL` opens a window on this machine that shows LABEL first, as `telar gui
  --machine LABEL` does ([Machine presentation](machine-presentation.md)). It
  refuses `--remote` or a second machine beside it.
- A disabled profile still receives dispatch; `enabled` only decides whether
  windows connect.
- `worktree create --machine` and `worktree fetch --machine` cannot be
  forwarded whole, because their Git transfer starts here; see
  [Worktree dispatch](worktree-dispatch.md).

## Validation

- `src/cli/arguments/MachineDispatchOptions.zig` tests both flag forms and
  missing labels or commands.
- `src/cli/dispatch_argv.zig` tests that quotes, `$(…)`, whitespace, Unicode
  and empty arguments survive, and that foreign words are refused.
- `src/cli/machine_dispatch.zig` tests the remote command line and its
  decoding, and the command length bound.
- Against the Linux SSH box (`tools/local-docker`): `--machine` with
  `machine list`, `pane list --json`, a quoted argument, a failing remote
  command's exit status, and an unreachable machine.

## General commands and artifacts

`telar --machine box exec -- PROGRAM ARGUMENTS...` starts a destination-runtime
execution with separate raw streams, stable status/output/cancel operations and
no Git requirement. Its default cwd is destination HOME, in an explicitly owned
administration workspace. See [execution](execution.md).

`repository prepare --machine box` and remote `worktree create` prepare a missing
clone using source-side committed history. `file put/get` transport explicit
artifacts through raw streams; declared project setup gates task launch. See
[repository preparation](repository-preparation.md). These use the same managed
SSH and encoded argv contract, with no ad hoc SSH fallback or provider login.
