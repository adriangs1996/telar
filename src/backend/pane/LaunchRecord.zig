const core = @import("telar-core");
const std = @import("std");
/// Bounded copy of the command a pane was launched with, kept so a session
/// checkpoint can relaunch it. Panes whose command does not fit, or which
/// replaced their environment, are not restorable and record nothing.
const LaunchRecord = @This();

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
pub fn capture(self: *LaunchRecord, launch: core.LaunchView) void {
    self.* = .{};
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

        @memcpy(self.bytes[len .. len + argument.len], argument);
        len += argument.len;
        self.bytes[len] = 0;
        len += 1;
        count += 1;
    }

    self.len = @intCast(len);
    self.count = count;
}

pub fn restorable(self: *const LaunchRecord) bool {
    return self.count != 0;
}

pub fn slice(self: *const LaunchRecord) []const u8 {
    return self.bytes[0..self.len];
}
