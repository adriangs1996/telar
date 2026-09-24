//! Total accessors over `std.json.Value`: a missing key or a value of the
//! wrong kind reads as null or empty instead of failing.
const std = @import("std");

/// The member `key` of an object, or null.
///
/// ```zig
/// const params = json.field(message, "params");
/// ```
pub fn field(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

/// The string, or empty for any other kind.
///
/// ```zig
/// const method = json.string(json.field(message, "method"));
/// ```
pub fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}

/// Whether `value` is the string `expected`.
///
/// ```zig
/// if (json.is(json.field(message, "method"), "turn/completed")) finish();
/// ```
pub fn is(value: std.json.Value, expected: []const u8) bool {
    return std.mem.eql(u8, string(value), expected);
}

/// Writes `value` as one JSONL record into `buffer`.
///
/// ```zig
/// const line = try json.encode(&buffer, request);
/// ```
pub fn encode(buffer: []u8, value: anytype) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{f}\n", .{std.json.fmt(value, .{})});
    return writer.buffered();
}

test "accessors read missing and mistyped members as empty" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"a\":\"x\",\"n\":1}", .{});
    defer parsed.deinit();
    try std.testing.expect(is(field(parsed.value, "a"), "x"));
    try std.testing.expectEqualStrings("", string(field(parsed.value, "n")));
    try std.testing.expect(field(parsed.value, "missing") == .null);
    try std.testing.expect(field(field(parsed.value, "a"), "b") == .null);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("{\"a\":1}\n", try encode(&buffer, .{ .a = 1 }));
}
