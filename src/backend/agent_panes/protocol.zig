//! Codex app-server JSONL bounds, verified against the locally generated
//! Codex 0.154 schema. Unknown server requests receive an explicit RPC error.

const std = @import("std");

pub const max_line_bytes = 256 * 1024;
pub const max_json_bytes = 2 * 1024 * 1024;
pub const max_write_bytes = 64 * 1024;
pub const queue_depth = 8;
pub const max_approvals = 8;
pub const Event = union(enum) {
    line: anyerror![]const u8,
    command: anyerror!@import("command.zig").Command,
    deadline: anyerror!void,
    resume_deadline: anyerror!void,
    command_deadline: anyerror!void,
};
pub const WriteEvent = union(enum) {
    written: anyerror!void,
    deadline: anyerror!void,
};

pub fn field(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

pub fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}

pub fn is(value: std.json.Value, expected: []const u8) bool {
    return std.mem.eql(u8, string(value), expected);
}

pub fn encode(buffer: []u8, value: anytype) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{f}\n", .{std.json.fmt(value, .{})});
    return writer.buffered();
}
