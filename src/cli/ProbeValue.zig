//! One bounded value a machine probe reported: a path, a version line.
const std = @import("std");
const ProbeValue = @This();

/// The longest value a probe line carries, in bytes.
pub const max_bytes = 255;

bytes: [max_bytes]u8 = undefined,
len: u8 = 0,

/// Copies `value`, refusing one longer than a probe line may carry.
///
/// ```zig
/// const home = try ProbeValue.init("/home/dev");
/// ```
pub fn init(value: []const u8) !ProbeValue {
    if (value.len > max_bytes) {
        return error.MachineProbeUnreadable;
    }

    var result: ProbeValue = .{};
    @memcpy(result.bytes[0..value.len], value);
    result.len = @intCast(value.len);
    return result;
}

pub fn slice(self: *const ProbeValue) []const u8 {
    return self.bytes[0..self.len];
}
