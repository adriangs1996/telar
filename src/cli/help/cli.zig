//! `telar cli --help` and the help of its commands.

const std = @import("std");
const FamilyHelp = @import("../FamilyHelp.zig");
const cli_install = @import("../cli_install.zig");

pub const family: FamilyHelp = .{
    .summary = "Link this executable as `telar` into a bin directory, for shells and agents",
    .usage = "telar cli install|uninstall|status [--dir DIR]",
    .text = std.fmt.comptimePrint(
        \\An application bundle exposes its command line this way. Inside a pane the running
        \\telar is always TELAR_BIN_PATH, whatever PATH says. Contacts no runtime.
        \\
        \\Arguments:
        \\  --dir DIR        The directory of the link (default {s}).
        \\
    , .{cli_install.default_dir}),
    .commands = &.{
        .{
            .name = "install",
            .summary = "Create or replace the `telar` symlink",
            .usage = "telar cli install [--dir DIR]",
            .text =
            \\Effects: replaces an existing symlink, never a regular file. Results: `telar cli:
            \\installed LINK -> TARGET`; on permission denied, a hint to rerun with sudo or pass
            \\`--dir ~/.local/bin`. Exit 0 or 1.
            \\
            ,
            .examples = &.{ &.{ "cli", "install" }, &.{ "cli", "install", "--dir", "/home/dev/.local/bin" } },
        },
        .{
            .name = "uninstall",
            .summary = "Remove the `telar` symlink",
            .usage = "telar cli uninstall [--dir DIR]",
            .text =
            \\Effects: removes the link when present. Results: `telar cli: removed LINK`. Exit 0.
            \\
            ,
            .examples = &.{&.{ "cli", "uninstall", "--dir", "/home/dev/.local/bin" }},
        },
        .{
            .name = "status",
            .summary = "Say where the `telar` symlink points",
            .usage = "telar cli status [--dir DIR]",
            .text =
            \\Results: `telar cli: LINK -> TARGET` or `telar cli: LINK is not installed`. Exit 0.
            \\
            ,
            .examples = &.{&.{ "cli", "status" }},
        },
    },
};
