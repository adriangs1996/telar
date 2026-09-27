# Machine profiles

`telar machine …` saves the machines an account can reach in
`$XDG_CONFIG_HOME/telar/machines.json` (or `~/.config/telar/machines.json`).
The CLI edits the file; windows follow it through their configuration watch.
Nothing here touches a runtime.

## End-to-end path

```text
telar machine add box dev@box --color red --check
        |
MachineOptions.parse                      src/cli/arguments/MachineOptions.zig
        |
machine_profiles.run                      src/cli/machine_profiles.zig
        |   machine_profiles.load: privatefile.read, owner-only regular file, 16 KiB,
        |   MachineProfiles.parse: version 1, no unknown fields
        |
MachineId.generate + MachineProfile.init  validation of label, destination, color
        |   --check: remote.discover over the managed SSH connection first
        |
MachineProfiles.add                       unique id and label, 16 profiles at most
        |
MachineProfiles.writeJson -> privatefile.replace
            owner-only temporary file, fsync, rename over machines.json
```

`remove`, `rename`, `enable` and `disable` follow the same load, change and
replace path. `list` and `check` only read.

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
  whitespace or control bytes, valid UTF-8, at most 255 bytes.
- `color` is `#RRGGBB` or a theme role name; windows resolve the name.
- `enabled` says whether windows connect to the machine. The CLI dispatches to
  a disabled machine all the same.
- `local_label` names the local machine; without it, the host name does.

Hand edits are valid. A file that fails validation, is readable by anyone but
its owner, or is a symlink, is refused and left untouched.

## Checking a machine

`telar machine check LABEL` and `add --check` run remote attach's discovery:
`ssh … telar server endpoint` through the managed options in
`src/client/machines/SshOptions.zig`. It reports the remote home, login shell and runtime
socket, or the SSH error. Discovery starts the remote runtime when none is
running, as attaching would; it never installs anything.

## Validation

- `src/core/MachineId.zig`, `src/core/MachineProfile.zig` and
  `src/core/MachineProfiles.zig` test the written form, field validation,
  JSON round trips, hand-written files, conflicts and capacity.
- `lib/privatefile` tests private replacement, refusal of shared files,
  symlinks and oversized files, and the fingerprint the watch uses.
- `src/cli/arguments/MachineOptions.zig` tests the grammar of every action.
- `src/cli/machine_profiles.zig` tests that a saved file loads back.
