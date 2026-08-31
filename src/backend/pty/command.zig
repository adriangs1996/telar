//! Borrowed process command passed across the pane-launch boundary.

const std = @import("std");
const ChildEnvironment = @import("environment.zig").ChildEnvironment;

pub const max_args = 64;

/// A borrowed command description. The argument strings must outlive `spawn`.
pub const Command = struct {
    file: [*:0]const u8,
    argv: [max_args:null]?[*:0]const u8 = @splat(null),
    cwd: ?[*:0]const u8 = null,
    environment: ?*const ChildEnvironment = null,

    pub fn fromArgv(args: []const [*:0]const u8) !Command {
        if (args.len == 0) return error.MissingCommand;
        // `argv` holds `max_args` slots plus a null sentinel, so exactly
        // `max_args` arguments fit.
        if (args.len > max_args) return error.TooManyArguments;

        var command: Command = .{ .file = args[0] };
        for (args, 0..) |arg, index| command.argv[index] = arg;
        return command;
    }
};

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
