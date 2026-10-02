//! `telar repository --help` and the help of its commands.

const std = @import("std");
const FamilyHelp = @import("../FamilyHelp.zig");
const repository_prepare = @import("../repository_prepare.zig");

pub const family: FamilyHelp = .{
    .summary = "Prepare a clone of this repository on another machine from committed history alone",
    .usage = "telar repository prepare --machine LABEL [--from REF] [--workspace PATH|ID] [--json]",
    .commands = &.{
        .{
            .name = "prepare",
            .summary = "Send committed history to a machine and publish or update its clone",
            .usage = "telar repository prepare --machine LABEL [--from REF] [--workspace PATH|ID] [--json]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --machine LABEL  Required: a saved machine other than this one.
                \\  --from REF       The commit to send (default HEAD).
                \\  --workspace X    Which clone to reuse there, when several match.
                \\
                \\Effects: checks the repository is whole (shallow or partial clones, submodules and
                \\LFS are refused), bundles the history up to REF (at most {d} MiB), and streams it
                \\to the machine through `telar exec`, where `repository receive` verifies it and
                \\fetches into an existing clone (found by the origin's identity, branches and
                \\checkout preserved) or publishes a new one under its $XDG_DATA_HOME/telar/
                \\repositories. Only commits travel: uncommitted files stay here and are counted on
                \\stderr. No credential, key or configuration leaves this machine. Remote
                \\`worktree create` runs this for you.
                \\
                \\Results: JSON `path`, `commit`, `repository`, `reused`, `repository_ready`,
                \\`environment` (`not_run`: setup is `project setup`'s). Exit 0; 1 with the reason on
                \\stderr. Never fall back to cloning through a provider yourself.
                \\
            , .{repository_prepare.max_bundle_bytes / (1024 * 1024)}),
            .examples = &.{&.{ "repository", "prepare", "--machine", "box", "--from", "HEAD", "--json" }},
        },
        .{
            .name = "receive",
            .summary = "The destination side of `prepare`: telar runs it there over exec",
            .usage = "telar repository receive --identity ID --transport URL --commit SHA --ref REF --bytes N [--workspace PATH|ID]",
            .hidden = true,
            .text =
            \\Reads a Git bundle of N bytes from stdin and publishes or updates the clone. Run by
            \\`telar repository prepare` on the other machine; not meant to be typed.
            \\
            ,
            .examples = &.{&.{ "repository", "receive", "--identity", "github.com/o/r", "--transport", "ssh://git@github.com/o/r.git", "--commit", "0000000000000000000000000000000000000000", "--ref", "refs/heads/main", "--bytes", "0" }},
        },
    },
};
