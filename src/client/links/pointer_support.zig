//! Mouse-gesture ownership for textual links inside pane content.

const Pointer = @import("Pointer.zig");
const TargetType = @import("LinkTarget.zig");
const std = @import("std");

pub const Kind = enum {
    press,
    release,
    drag,
    other,
};

test "a link press owns its drag and release" {
    var pointer: Pointer = .{};
    const target = try TargetType.init("https://example.com");

    const pressed = pointer.handle(.{ .kind = .press, .left_button = true }, target);
    try std.testing.expect(pressed.consumed);
    try std.testing.expectEqualStrings(target.uri(), pressed.open.?.uri());
    try std.testing.expect(pointer.handle(.{ .kind = .drag, .left_button = true }, null).consumed);
    try std.testing.expect(pointer.handle(.{ .kind = .release, .left_button = true }, null).consumed);
    try std.testing.expect(!pointer.owned);
}

test "non-link and non-left presses remain unowned" {
    var pointer: Pointer = .{};
    const target = try TargetType.init("https://example.com");

    try std.testing.expect(!pointer.handle(.{ .kind = .press, .left_button = true }, null).consumed);
    try std.testing.expect(!pointer.handle(.{ .kind = .press, .left_button = false }, target).consumed);
}
