//! `telar machine --help` and the help of its commands, and the `--machine`
//! prefix that runs any command on a saved machine.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");
const machine_dispatch = @import("../machine_dispatch.zig");
const machine_setup = @import("../machine_setup.zig");

pub const family: FamilyHelp = .{
    .summary = "Save, check and set up other machines; `telar --machine LABEL COMMAND...` runs a command there",
    .usage = "telar machine COMMAND [LABEL] [options]\n       telar --machine LABEL FAMILY COMMAND [ARGS...]",
    .text = std.fmt.comptimePrint(
        \\A machine is a computer whose runtime telar reaches over SSH; it runs one runtime per
        \\account and knows nothing of the others. Profiles live in machines.json under
        \\$XDG_CONFIG_HOME/telar (else ~/.config/telar): id, label, SSH destination, color,
        \\whether windows connect to it and, after setup, where its telar is. Never a credential.
        \\This machine needs no profile: it answers to the label the file gives it or its host
        \\name. At most {d} profiles; a label is 1 to {d} characters of letters, digits, `.`,
        \\`_` and `-`. `add`, `remove`, `rename`, `enable`, `disable` and `list` edit the file
        \\only; `check` and `setup` reach the machine.
        \\
        \\`telar --machine LABEL COMMAND...`, with `--machine` as the first word, runs one telar
        \\command on that machine's runtime: the command's stdin, stdout, stderr and exit
        \\status pass through, and every id it prints or takes belongs to that machine. A
        \\failure there is a failure: nothing falls back to this machine; an SSH failure exits
        \\255. The local label runs the command here. `--machine` is never inherited by a pane,
        \\so pass it on every command meant for another machine. `telar --machine LABEL` alone,
        \\or with window options, opens a window showing that machine. The command line sent
        \\is at most {d} KiB. `worktree create --machine` and `worktree fetch --machine` are
        \\not forwarded whole: their Git transfer starts here.
        \\With --help, this binary prints its help locally before resolving the machine.
        \\
    , .{ core.MachineProfiles.capacity, core.MachineProfile.max_label_bytes, machine_dispatch.max_command_bytes / 1024 }),
    .commands = &.{
        .{
            .name = "add",
            .summary = "Save a machine: a label and an SSH destination",
            .usage = "telar machine add LABEL DESTINATION [--color COLOR] [--disabled] [--check] [--setup [--binary PATH] [--skip agents,config,login]] [--json]",
            .text =
            \\Arguments:
            \\  DESTINATION      An SSH destination (`user@host`, a `~/.ssh/config` host...); unique.
            \\  --color COLOR    `#RRGGBB` or a lowercase name, for the window's chrome.
            \\  --disabled       Save it without windows connecting to it; dispatch still works.
            \\  --check          Reach the machine first (as `machine check`) and refuse an
            \\                   unreachable one.
            \\  --setup          Set it up right after saving (as `machine setup`), with its options.
            \\
            \\Effects: writes machines.json atomically. Without --check or --setup nothing is
            \\contacted; with them the machine's runtime is started as `check` does.
            \\
            \\Results: nothing, or the check/setup report (JSON with --json). Exit 0; 1 with the
            \\reason on stderr (taken label or destination, invalid label, unreachable).
            \\
            ,
            .examples = &.{ &.{ "machine", "add", "box", "dev@box.example.com", "--color", "#3366ff" }, &.{ "machine", "add", "box", "dev@box", "--setup", "--skip", "login", "--json" } },
        },
        .{
            .name = "setup",
            .summary = "Make a machine ready: this telar build, the agents, their integration, configuration and logins",
            .usage = "telar machine setup LABEL|DESTINATION [--label LABEL] [--binary PATH] [--skip agents,config,login] [--confirm] [--json]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  LABEL|DESTINATION  A saved machine, or a new SSH destination that gets saved
                \\                   under --label (default: derived from its host name).
                \\  --binary PATH    A telar executable built for the machine; development builds
                \\                   need one.
                \\  --skip STEPS     Leave out `agents`, `config` and/or `login`.
                \\  --confirm        Ask on the terminal before changing anything (refused without
                \\                   a terminal or with --json).
                \\
                \\Effects, in order, each idempotent: ssh, platform, telar (this exact build
                \\installed under ~/.local/share/telar/versions on the machine, no sudo), runtime
                \\(a runtime of another build is stopped only after a `y` on the terminal, then
                \\~/.local/bin/telar is linked), profile (saved and enabled), agents (installed),
                \\integrations, configuration (allowlisted sync, no secrets), logins (each agent's
                \\own login there; `telar workspace create -- codex login` opens them wide enough to
                \\read the URL with `pane read`), check. Probes wait {d} s, installs {d} s.
                \\
                \\Results: numbered step lines with ok|changed|skipped|failed|pending and a verdict;
                \\JSON `label`, `destination`, `ready`, `pending`, `changed`, `steps` (step, status,
                \\detail, notes). Exit 0, also with a login still pending; 1 when a step failed.
                \\
            , .{ machine_setup.probe_timeout_s, machine_setup.install_timeout_s }),
            .examples = &.{ &.{ "machine", "setup", "box", "--json" }, &.{ "machine", "setup", "dev@box", "--label", "box", "--binary", "/tmp/telar", "--skip", "login,config" } },
        },
        .{
            .name = "list",
            .summary = "List the saved machines, and this one",
            .usage = "telar machine list [--json]",
            .text =
            \\Effects: reads machines.json. Contacts nothing.
            \\
            \\Results: `LOCAL\tlocal` first, then `label\tdestination\tenabled|disabled[\tcolor]
            \\[\tlogins: ...]` per machine; JSON `local` and `machines` (id, label, destination,
            \\color, enabled, telar_path, logins). Exit 0.
            \\
            ,
            .examples = &.{&.{ "machine", "list", "--json" }},
        },
        .{
            .name = "check",
            .summary = "Reach a machine's runtime over SSH and compare wire schemas",
            .usage = "telar machine check LABEL [--json]",
            .text =
            \\Effects: runs `telar server endpoint` on the machine, which starts its runtime when
            \\none runs.
            \\
            \\Results: JSON `label`, `reachable`, and when reachable `schema`, `local_schema`,
            \\`compatible`, `home`, `shell`, `socket`, else `error`, `detail`. Exit 0; 1 when
            \\unreachable or the schemas differ (run `machine setup` to install this build there).
            \\
            ,
            .examples = &.{&.{ "machine", "check", "box", "--json" }},
        },
        .{
            .name = "remove",
            .summary = "Forget a saved machine",
            .usage = "telar machine remove LABEL",
            .text =
            \\Effects: removes the profile from machines.json; nothing on the machine changes.
            \\Results: nothing; exit 0, 1 when the label is unknown or local.
            \\
            ,
            .examples = &.{&.{ "machine", "remove", "box" }},
        },
        .{
            .name = "rename",
            .summary = "Change a machine's label; its id stays",
            .usage = "telar machine rename LABEL NEW_LABEL",
            .text =
            \\Effects: edits machines.json. Commands and windows use the new label from then on.
            \\Results: nothing; exit 0, 1 when refused (unknown, taken or local label).
            \\
            ,
            .examples = &.{&.{ "machine", "rename", "box", "gpu" }},
        },
        .{
            .name = "enable",
            .summary = "Let windows connect to a machine again",
            .usage = "telar machine enable LABEL",
            .text =
            \\Effects: edits machines.json. `enabled` only decides whether windows connect;
            \\`--machine LABEL` dispatch works either way. Results: nothing; exit 0 or 1.
            \\
            ,
            .examples = &.{&.{ "machine", "enable", "box" }},
        },
        .{
            .name = "disable",
            .summary = "Keep windows from connecting to a machine",
            .usage = "telar machine disable LABEL",
            .text =
            \\Effects: edits machines.json. Dispatch with `--machine LABEL` still works.
            \\Results: nothing; exit 0 or 1.
            \\
            ,
            .examples = &.{&.{ "machine", "disable", "box" }},
        },
        .{
            .name = "receive-config",
            .summary = "The machine's side of `setup`: receives the allowlisted configuration on stdin",
            .usage = "telar machine receive-config",
            .hidden = true,
            .text =
            \\Run by `telar machine setup` on the machine being set up; not meant to be typed.
            \\
            ,
            .examples = &.{&.{ "machine", "receive-config" }},
        },
    },
};
