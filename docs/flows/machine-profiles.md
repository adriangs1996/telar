# Machine profiles

`telar machine …` saves the machines an account can reach in
`$XDG_CONFIG_HOME/telar/machines.json` (or `~/.config/telar/machines.json`).
The CLI and the window's machine list edit the file; windows follow it
within a second ([Machine presentation](machine-presentation.md)). Nothing
here touches a runtime.

## End-to-end path

```text
telar machine add box dev@box --color red --check
        |
MachineOptions.parse                      src/cli/arguments/MachineOptions.zig
        |
machine_profiles.run                      src/cli/machine_profiles.zig
        |   profile_file.load: privatefile.read, owner-only regular file, 16 KiB,
        |   MachineProfiles.parse: version 1, no unknown fields
        |
machine_profiles.newProfile              src/client/machines/machine_profiles.zig:
        |   refuses this machine's label, MachineId.generate + MachineProfile.init
        |   validate label, destination, color
        |   --check: remote.discover over the managed SSH connection first
        |
machine_profiles.store
        |   privatefile.lock: flock on machines.json.lock, waits for a holder
        |   profile_file.load again, machine_profiles.change:
        |   MachineProfiles.add: unique id, label and destination, 16 at most
        |
MachineProfiles.writeJson -> privatefile.replace
            owner-only temporary file, fsync, rename over machines.json;
            closing the lock file releases the lock
```

`remove`, `rename`, `enable` and `disable` go straight to
`machine_profiles.store`, which the window's list also uses from a
background job (`machine_profiles.start`, `write`, `finish`). A rename, like
an add, refuses this machine's label. `list` and `check` only read.

## Concurrent changes

Every change reads, changes and replaces `machines.json` while it holds an
exclusive flock(2) on `machines.json.lock` beside it, so the CLI and every
window take turns: two `telar machine add` at once, or one beside a change
made in a window, both reach the file. The lock file is owner-only and
never removed, because removing a locked file lets the next caller lock a
new one while the old holder still works. Reading needs no lock: the
replacement is a rename, so a reader sees the old file or the new one.
`add --check` validates the fields first, runs the check without the lock,
then makes the change under it against the file as it is then, so a label
taken meanwhile is refused.

## The file

```json
{"version":1,"local_label":"laptop","machines":[
  {"id":"m-3f9c2a00b001","label":"box","destination":"dev@box","color":"red","enabled":true}
]}
```

- `id` is `m-` and twelve lowercase hex digits, drawn at random once. A rename
  keeps it.
- `label` is one to 32 ASCII letters, digits, `.`, `_` or `-`, starting with a
  letter or a digit. Labels are unique, and no profile may take the local
  machine's label.
- `destination` passes remote attach's validation: no leading `-`, no
  whitespace or control bytes, valid UTF-8, at most 255 bytes. Destinations
  are unique: one destination is one runtime, and two profiles for it
  would give a window two clients with one identity there.
- `color` is `#RRGGBB` or a theme role name; windows resolve the name.
- `enabled` says whether windows connect to the machine. The CLI dispatches to
  a disabled machine all the same.
- `telar_path` is where `telar machine setup` installed telar on that
  machine: absolute, at most 255 bytes, only ASCII letters, digits and
  `/._+-`, since it goes unquoted into command lines any remote shell
  parses. Discovery, the bridge and dispatch run it instead of `telar`
  from the PATH of non-interactive SSH sessions; without it they run
  `telar`. A window reconnects a machine whose path changed.
- `local_label` names the local machine; without it, the host name does.

Hand edits are valid. A file that fails validation, is readable by anyone but
its owner, or is a symlink, is refused and left untouched.

## Checking a machine

`telar machine check LABEL` and `add --check` run remote attach's discovery:
`ssh … telar server endpoint` through the managed options in
`src/client/machines/SshOptions.zig`. It reports the remote home, login shell and runtime
socket, its wire schema and whether it matches this telar, or the SSH
error. Discovery starts the remote runtime when none is running, as
attaching would; it never installs anything.

## Validation

- `src/core/MachineId.zig`, `src/core/MachineProfile.zig` and
  `src/core/MachineProfiles.zig` test the written form, field validation,
  JSON round trips, hand-written files, conflicts (ids, labels and
  destinations) and capacity.
- `lib/privatefile` tests private replacement, refusal of shared files,
  symlinks and oversized files, the fingerprint the watch uses, and that a
  lock excludes a second holder until it is released.
- `src/cli/arguments/MachineOptions.zig` tests the grammar of every action.
- `src/client/machines/profile_file.zig` tests that a saved file loads back;
  `src/client/machines/machine_profiles.zig` tests that four writers adding
  at once all reach the file.
- Two `telar machine add` loops of eight adds each, run at once 20 times:
  without the lock, 4 rounds lost an add; with it, none did.
