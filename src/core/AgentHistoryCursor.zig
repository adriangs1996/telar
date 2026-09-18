const std = @import("std");
const limits = @import("agent_history.zig");
const Cursor = @This();

bytes: [limits.max_cursor_bytes]u8 = undefined,
len: u16 = 0,

/// Owns an opaque provider position, including any text continuation.
/// Example: `const cursor = try AgentHistoryCursor.init(response.before);`
pub fn init(value: []const u8) !Cursor {
    if (value.len > limits.max_cursor_bytes or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidAgentHistoryCursor;
    }

    var cursor: Cursor = .{ .len = @intCast(value.len) };
    @memcpy(cursor.bytes[0..value.len], value);
    return cursor;
}

/// Example: `try writer.writeAll(cursor.slice());`
pub fn slice(cursor: *const Cursor) []const u8 {
    return cursor.bytes[0..cursor.len];
}
