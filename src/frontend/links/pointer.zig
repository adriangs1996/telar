//! Mouse-gesture ownership for textual links inside pane content.

const std = @import("std");
const target_mod = @import("target.zig");

pub const Kind = enum {
    press,
    release,
    drag,
    other,
};

pub const Command = struct {
    kind: Kind,
    left_button: bool,
};

pub const Outcome = struct {
    consumed: bool = false,
    open: ?target_mod.Target = null,
};

pub const Pointer = struct {
    owned: bool = false,

    /// Claims a left-button gesture only when its press begins over a link.
    ///
    /// ```zig
    /// const outcome = pointer.handle(command, target);
    /// ```
    pub fn handle(pointer: *Pointer, command: Command, target: ?target_mod.Target) Outcome {
        if (pointer.owned) {
            if (command.kind == .release) {
                pointer.owned = false;
            } else if (command.kind == .press) {
                pointer.owned = false;
            } else {
                return .{ .consumed = command.kind == .drag };
            }

            if (command.kind == .release) {
                return .{ .consumed = true };
            }
        }

        if (command.kind != .press or !command.left_button) {
            return .{};
        }

        const link_target = target orelse return .{};
        pointer.owned = true;

        return .{ .consumed = true, .open = link_target };
    }
};

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
