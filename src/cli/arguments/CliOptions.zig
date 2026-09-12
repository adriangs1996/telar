//! `telar cli install|uninstall|status [--dir DIR]`: the command-line entry
//! an application bundle exposes to shells and agents.
const std = @import("std");
const CliOptions = @This();

pub const Action = enum { install, uninstall, status };

action: Action,
dir: ?[*:0]const u8 = null,

/// Example: `const options = try CliOptions.parse(args);`.
pub fn parse(args: []const [*:0]const u8) !CliOptions {
    if (args.len < 1) {
        return error.MissingCliAction;
    }

    const name = std.mem.span(args[0]);
    const action: Action = if (std.mem.eql(u8, name, "install"))
        .install
    else if (std.mem.eql(u8, name, "uninstall"))
        .uninstall
    else if (std.mem.eql(u8, name, "status"))
        .status
    else
        return error.UnknownCliAction;

    var options: CliOptions = .{ .action = action };
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (!std.mem.eql(u8, std.mem.span(args[index]), "--dir")) {
            return error.UnknownCliOption;
        }

        if (options.dir != null) {
            return error.DuplicateDirOption;
        }

        if (index + 1 >= args.len) {
            return error.MissingDirPath;
        }

        options.dir = args[index + 1];
    }

    return options;
}

test "cli install accepts a directory" {
    const args = [_][*:0]const u8{ "install", "--dir", "/tmp/bin" };
    const options = try CliOptions.parse(&args);

    try std.testing.expectEqual(Action.install, options.action);
    try std.testing.expectEqualStrings("/tmp/bin", std.mem.span(options.dir.?));
}

test "cli refuses unknown actions and options" {
    try std.testing.expectError(error.UnknownCliAction, CliOptions.parse(&.{"link"}));
    try std.testing.expectError(error.UnknownCliOption, CliOptions.parse(&.{ "status", "--path", "x" }));
    try std.testing.expectError(error.MissingDirPath, CliOptions.parse(&.{ "install", "--dir" }));
}
