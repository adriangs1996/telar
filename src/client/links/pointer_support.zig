//! Mouse-gesture ownership for textual links inside pane content.

const std = @import("std");
const target_mod = @import("root.zig").target;

pub const Kind = enum {
    press,
    release,
    drag,
    other,
};

pub const Command = @import("Command.zig");

pub const Outcome = @import("Outcome.zig");

pub const Pointer = @import("Pointer.zig");

test "a link press owns its drag and release" {
    var pointer: Pointer = .{};
    const target = try target_mod.Target.init("https://example.com");

    const pressed = pointer.handle(.{ .kind = .press, .left_button = true }, target);
    try std.testing.expect(pressed.consumed);
    try std.testing.expectEqualStrings(target.uri(), pressed.open.?.uri());
    try std.testing.expect(pointer.handle(.{ .kind = .drag, .left_button = true }, null).consumed);
    try std.testing.expect(pointer.handle(.{ .kind = .release, .left_button = true }, null).consumed);
    try std.testing.expect(!pointer.owned);
}

test "non-link and non-left presses remain unowned" {
    var pointer: Pointer = .{};
    const target = try target_mod.Target.init("https://example.com");

    try std.testing.expect(!pointer.handle(.{ .kind = .press, .left_button = true }, null).consumed);
    try std.testing.expect(!pointer.handle(.{ .kind = .press, .left_button = false }, target).consumed);
}
