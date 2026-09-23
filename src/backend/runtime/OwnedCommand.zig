const CommandType = @import("../pty/Command.zig");
const std = @import("std");
const core = @import("telar-core");
const ChildEnvironment = @import("../pty/ChildEnvironment.zig");
const OwnedCommand = @This();

command: CommandType,
arguments: []const [:0]u8,
cwd: [:0]u8,
gpa: std.mem.Allocator,

/// Copies a launch's argv and working directory into owned, NUL-terminated
/// storage for the PTY layer.
///
/// ```zig
/// var command = try OwnedCommand.init(gpa, launch, cwd, environment);
/// defer command.deinit();
/// ```
pub fn init(gpa: std.mem.Allocator, launch: core.LaunchView, cwd_path: []const u8, environment: *const ChildEnvironment) !OwnedCommand {
    if (launch.environment_mode != .inherit_runtime or launch.environment_count != 0) {
        return error.UnsupportedEnvironment;
    }

    const arguments = try gpa.alloc([:0]u8, launch.argument_count);
    errdefer gpa.free(arguments);
    var initialized: usize = 0;
    errdefer for (arguments[0..initialized]) |argument| gpa.free(argument);

    var iterator = launch.arguments();
    while (try iterator.next()) |argument| {
        arguments[initialized] = try gpa.dupeZ(u8, argument);
        initialized += 1;
    }
    const cwd = try gpa.dupeZ(u8, cwd_path);
    errdefer gpa.free(cwd);

    var command: CommandType = .{
        .file = arguments[0].ptr,
        .cwd = cwd.ptr,
        .environment = environment,
    };
    for (arguments, 0..) |argument, index| command.argv[index] = argument.ptr;
    return .{ .command = command, .arguments = arguments, .cwd = cwd, .gpa = gpa };
}

pub fn deinit(command: *OwnedCommand) void {
    for (command.arguments) |argument| command.gpa.free(argument);
    command.gpa.free(command.arguments);
    command.gpa.free(command.cwd);
}
