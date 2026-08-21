//! Proof that the width provider is a seam and not a comment.
//!
//! This target builds `ui.zig` against `unicode_fake.zig` instead of the
//! emulator's tables. Nothing in `ui.zig` changes; only the module binding in
//! `build.zig` does. Every assertion here would fail against the real tables,
//! which is the point: it can only pass if the substitution took effect.

const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

test "layout follows the injected table, not the bytes" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Plain ASCII, which every real table calls one column wide.
    try testing.expectEqual(@as(u16, 6), ui.measure("abc"));

    const advanced = buf.writeText(buf.area(), 0, 0, "abc", .{});
    try testing.expectEqual(@as(u16, 6), advanced);

    // Two columns each means the second character starts at column two, and
    // column one is the tail the diff must not draw into.
    try testing.expectEqualStrings("a", buf.at(0, 0).?.text());
    try testing.expectEqual(@as(u8, 0), buf.at(1, 0).?.width);
    try testing.expectEqualStrings("b", buf.at(2, 0).?.text());
}

test "truncation measures with the injected table too" {
    // A measurement and a draw that consult different tables is the bug this
    // whole arrangement exists to make impossible. Right alignment and
    // ellipsis both depend on them agreeing.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 10, 1);
    defer buf.deinit();

    // "abcd" is eight columns here, so it does not fit in five.
    const written = buf.writeTruncated(buf.area(), 0, 0, "abcd", 5, .{});
    try testing.expect(written <= 5);
    try testing.expectEqualStrings("a", buf.at(0, 0).?.text());
}
