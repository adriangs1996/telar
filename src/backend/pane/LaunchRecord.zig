const core = @import("telar-core");
const std = @import("std");
/// Copy of the command a pane was launched with, kept so a session
/// checkpoint can relaunch it. It holds any command a launch accepts, in a
/// heap buffer sized to it; only panes that replaced their environment
/// record nothing, since a checkpoint never stores one.
const LaunchRecord = @This();

bytes: []u8 = &.{},
count: u16 = 0,

/// Copies the arguments of one launch as NUL-terminated entries, replacing
/// what the record held.
///
/// ```zig
/// var record: LaunchRecord = .{};
/// defer record.deinit(gpa);
/// try record.capture(gpa, launch);
/// ```
pub fn capture(self: *LaunchRecord, gpa: std.mem.Allocator, launch: core.LaunchView) !void {
    self.deinit(gpa);
    if (launch.environment_mode != .inherit_runtime or launch.argument_count == 0) {
        return;
    }

    var measured = launch.arguments();
    var len: usize = 0;
    var count: u16 = 0;
    while (measured.next() catch null) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) {
            return;
        }

        len += argument.len + 1;
        count += 1;
    }

    const bytes = try gpa.alloc(u8, len);
    var arguments = launch.arguments();
    var written: usize = 0;
    while (arguments.next() catch null) |argument| {
        @memcpy(bytes[written..][0..argument.len], argument);
        written += argument.len;
        bytes[written] = 0;
        written += 1;
    }

    std.debug.assert(written == len);
    self.bytes = bytes;
    self.count = count;
}

/// Frees the copy; the record is empty afterwards.
///
/// ```zig
/// record.deinit(gpa);
/// ```
pub fn deinit(self: *LaunchRecord, gpa: std.mem.Allocator) void {
    gpa.free(self.bytes);
    self.* = .{};
}

pub fn restorable(self: *const LaunchRecord) bool {
    return self.count != 0;
}

pub fn slice(self: *const LaunchRecord) []const u8 {
    return self.bytes;
}
