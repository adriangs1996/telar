//! Mouse-gesture ownership for textual links inside pane content.

const Pointer = @import("Pointer.zig");
const TargetType = @import("LinkTarget.zig");
const std = @import("std");

pub const Kind = @import("../types/PointerSupportKind.zig").PointerSupportKind;

test "a link press owns its drag and release" {
    var pointer: Pointer = .{};
    const target = try TargetType.init("https://example.com");

    const pressed = pointer.handle(
        .{
            .kind = .press,
            .left_button = true,
        },
        target,
    );
    try std.testing.expect(pressed.consumed);
    try std.testing.expectEqualStrings(target.uri(), pressed.open.?.uri());
    try std.testing.expect(pointer.handle(
        .{
            .kind = .drag,
            .left_button = true,
        },
        null,
    ).consumed);
    try std.testing.expect(pointer.handle(
        .{
            .kind = .release,
            .left_button = true,
        },
        null,
    ).consumed);
    try std.testing.expect(!pointer.owned);
}

test "non-link and non-left presses remain unowned" {
    var pointer: Pointer = .{};
    const target = try TargetType.init("https://example.com");

    try std.testing.expect(!pointer.handle(
        .{
            .kind = .press,
            .left_button = true,
        },
        null,
    ).consumed);
    try std.testing.expect(!pointer.handle(
        .{
            .kind = .press,
            .left_button = false,
        },
        target,
    ).consumed);
}

test "right link press copies once and owns drag and release" {
    var pointer: Pointer = .{};
    const target = try TargetType.init("file:///tmp/a%20b.txt");
    const pressed = pointer.handle(
        .{
            .kind = .press,
            .left_button = false,
            .right_button = true,
        },
        target,
    );
    try std.testing.expect(pressed.consumed);
    try std.testing.expect(pressed.open == null);
    try std.testing.expectEqualStrings(target.uri(), pressed.copy.?.uri());
    const dragged = pointer.handle(
        .{
            .kind = .drag,
            .left_button = false,
            .right_button = true,
        },
        target,
    );
    try std.testing.expect(dragged.consumed and dragged.copy == null);
    const released = pointer.handle(
        .{
            .kind = .release,
            .left_button = false,
            .right_button = true,
        },
        target,
    );
    try std.testing.expect(released.consumed and released.copy == null);
    try std.testing.expect(!pointer.owned);
}
