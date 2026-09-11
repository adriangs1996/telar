/// A borrowed command description. The argument strings must outlive `spawn`.
const Command = @This();
const ChildEnvironment = @import("environment.zig").ChildEnvironment;
const source_namespace = @import("command_support.zig");
file: [*:0]const u8,
argv: [source_namespace.max_args:null]?[*:0]const u8 = @splat(null),
cwd: ?[*:0]const u8 = null,
environment: ?*const ChildEnvironment = null,

/// Builds a borrowed command and rejects empty or oversized argument
/// lists. Every argument must remain alive until `Session.spawn` returns.
///
/// ```zig
/// const args = [_][*:0]const u8{ "/bin/sh", "-l" };
/// const command = try Command.fromArgv(&args);
/// ```
pub fn fromArgv(args: []const [*:0]const u8) !Command {
    if (args.len == 0) {
        return error.MissingCommand;
    }

    // `argv` holds `max_args` slots plus a null sentinel, so exactly
    // `max_args` arguments fit.
    if (args.len > source_namespace.max_args) {
        return error.TooManyArguments;
    }

    var command: Command = .{ .file = args[0] };
    for (args, 0..) |arg, index| {
        command.argv[index] = arg;
    }

    return command;
}
