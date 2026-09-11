/// Bounded copy of the command a pane was launched with, kept so a session
/// checkpoint can relaunch it. Panes whose command does not fit, or which
/// replaced their environment, are not restorable and record nothing.
const LaunchRecord = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
pub const max_bytes = 1024;
pub const max_arguments = 32;

bytes: [max_bytes]u8 = undefined,
len: u16 = 0,
count: u16 = 0,

/// Copies the arguments of one launch as NUL-terminated entries.
///
/// ```zig
/// var record: LaunchRecord = .{};
/// record.capture(launch);
/// ```
pub fn capture(record: *LaunchRecord, launch: source_namespace.schema.LaunchView) void {
    record.* = .{};
    if (launch.environment_mode != .inherit_runtime or launch.argument_count == 0 or launch.argument_count > max_arguments) {
        return;
    }

    var arguments = launch.arguments();
    var len: usize = 0;
    var count: u16 = 0;
    while (arguments.next() catch null) |argument| {
        if (len + argument.len + 1 > max_bytes or std.mem.indexOfScalar(u8, argument, 0) != null) {
            return;
        }

        @memcpy(record.bytes[len .. len + argument.len], argument);
        len += argument.len;
        record.bytes[len] = 0;
        len += 1;
        count += 1;
    }

    record.len = @intCast(len);
    record.count = count;
}

pub fn restorable(record: *const LaunchRecord) bool {
    return record.count != 0;
}

pub fn slice(record: *const LaunchRecord) []const u8 {
    return record.bytes[0..record.len];
}
