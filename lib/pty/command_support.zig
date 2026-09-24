//! Borrowed process command passed across the pane-launch boundary.

const std = @import("std");
const Command = @import("Command.zig");

pub const max_args = 64;

test "an empty argument list is rejected" {
    const args = [_][*:0]const u8{};

    try std.testing.expectError(error.MissingCommand, Command.fromArgv(&args));
}

test "command arguments remain null terminated" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 7" };
    const command = try Command.fromArgv(&args);

    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.file));
    try std.testing.expectEqualStrings("exit 7", std.mem.span(command.argv[2].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), command.argv[3]);
}

test "a command accepts the schema's maximum argument count" {
    var args: [max_args][*:0]const u8 = @splat("x");
    args[0] = "/bin/true";
    const command = try Command.fromArgv(&args);

    try std.testing.expectEqualStrings("/bin/true", std.mem.span(command.file));
    try std.testing.expect(command.argv[max_args - 1] != null);
}

test "one argument past the limit is rejected" {
    const args: [max_args + 1][*:0]const u8 = @splat("x");

    try std.testing.expectError(error.TooManyArguments, Command.fromArgv(&args));
}
