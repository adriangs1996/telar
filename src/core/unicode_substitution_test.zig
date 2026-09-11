//! Proof that the width provider is a seam and not a comment.
//!
//! This target builds `ui/root.zig` against `unicode_fake.zig` instead of the
//! emulator's tables. Nothing in `ui/root.zig` changes; only the module binding in
//! `build.zig` does. Every assertion here would fail against the real tables,
//! which is the point: it can only pass if the substitution took effect.

const std = @import("std");
const BufferType = @import("ui/Buffer.zig");
const text_module = @import("ui/text.zig");

test "layout follows the injected table, not the bytes" {
    const gpa = std.testing.allocator;
    var buf = try BufferType.init(gpa, 20, 1);
    defer buf.deinit();

    // Plain ASCII, which every real table calls one column wide.
    try std.testing.expectEqual(@as(u16, 6), text_module.measure("abc"));

    const advanced = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "abc", .style = .{} });
    try std.testing.expectEqual(@as(u16, 6), advanced);

    // Two columns each means the second character starts at column two, and
    // column one is the tail the diff must not draw into.
    try std.testing.expectEqualStrings("a", buf.at(0, 0).?.text());
    try std.testing.expectEqual(@as(u8, 0), buf.at(1, 0).?.width);
    try std.testing.expectEqualStrings("b", buf.at(2, 0).?.text());
}

test "truncation measures with the injected table too" {
    // A measurement and a draw that consult different tables is the bug this
    // whole arrangement exists to make impossible. Right alignment and
    // ellipsis both depend on them agreeing.
    const gpa = std.testing.allocator;
    var buf = try BufferType.init(gpa, 10, 1);
    defer buf.deinit();

    // "abcd" is eight columns here, so it does not fit in five.
    const written = buf.writeTruncated(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "abcd", .max_width = 5, .style = .{} });
    try std.testing.expect(written <= 5);
    try std.testing.expectEqualStrings("a", buf.at(0, 0).?.text());
}
