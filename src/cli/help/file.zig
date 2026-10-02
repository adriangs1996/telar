//! `telar file --help` and the help of its commands.

const std = @import("std");
const FamilyHelp = @import("../FamilyHelp.zig");
const file_transfer = @import("../file_transfer.zig");

pub const family: FamilyHelp = .{
    .summary = "Publish a file from standard input, or write one to standard output, byte-exact",
    .usage = "telar file put ABS_PATH --bytes N | telar file get ABS_PATH",
    .text = std.fmt.comptimePrint(
        \\The transport for artifacts between machines, run under `telar --machine LABEL exec`
        \\so the bytes travel as raw streams and never as terminal screen text. Touches no
        \\runtime. Paths are absolute; every directory on the way must belong to the user and
        \\be writable by no one else. At most {d} MiB. Exit 0, or 1 with the reason on stderr.
        \\
    , .{file_transfer.max_bytes / (1024 * 1024)}),
    .commands = &.{
        .{
            .name = "put",
            .summary = "Read exactly N bytes from stdin and publish them at a new path",
            .usage = "telar file put ABS_PATH --bytes N",
            .text =
            \\Arguments:
            \\  ABS_PATH         Where the file appears; it must not exist.
            \\  --bytes N        The exact size; fewer or more bytes fail the transfer.
            \\
            \\Effects: streams stdin into an owner-only temporary file beside the path, checks
            \\the length, syncs it and renames it into place without ever replacing a file.
            \\
            \\Results: `{"bytes":N,"published":true}`; exit 1 and no file otherwise.
            \\
            ,
            .examples = &.{&.{ "file", "put", "/home/dev/brief.md", "--bytes", "1532" }},
        },
        .{
            .name = "get",
            .summary = "Write a regular file's bytes to stdout",
            .usage = "telar file get ABS_PATH",
            .text =
            \\Effects: reads one regular, user-owned file. Nothing else changes.
            \\
            \\Results: the raw bytes on stdout; exit 0. Through `exec`, falling behind the
            \\retained output is an explicit failure, not a short artifact: check the exit status.
            \\
            ,
            .examples = &.{&.{ "file", "get", "/home/dev/report.tar" }},
        },
    },
};
