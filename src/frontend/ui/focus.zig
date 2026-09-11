//! Who has the keyboard.
//!
//! Registered while drawing, in a layer, exactly the way clicks are - and one
//! rule then replaces every `if (a_dialog_is_open)` check an application would
//! otherwise repeat in each of its key handlers:
//!
//!   **Focus lives in the topmost layer that registered anything focusable.**

const std = @import("std");

// ---------------------------------------------------------------------------
// Focus
// ---------------------------------------------------------------------------

pub const Focus = @import("GenericFocus.zig").Type;

/// Columns `text` will occupy once drawn.
///
/// Shares the iterator `writeText` uses, so a measurement and a draw can never
/// disagree - which is what right alignment and truncation both depend on.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestId = union(enum) { field: u16, button: u16, dialog: u16 };
const TestFocus = Focus(TestId, 32);

/// One frame's worth of registrations, so the tests read like drawing code.
fn drawFrame(f: *TestFocus, base: []const TestId, overlay: ?[]const TestId) void {
    f.beginFrame();
    for (base) |id| f.register(id);
    if (overlay) |ids| {
        f.beginLayer();
        for (ids) |id| f.register(id);
        f.endLayer();
    }
    f.endFrame();
}

test "focus lands somewhere on the first frame" {
    // A UI that starts with nothing focused answers no keys until the user
    // finds something to click, which reads as broken rather than as empty.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "tab cycles and wraps within the layer" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);

    f.next();
    try testing.expectEqual(TestId{ .button = 1 }, f.focused().?);
    f.next();
    f.next();
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
    f.prev();
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
}

test "an overlay takes the keyboard the frame it appears" {
    // Nobody writes this. The dialog registered in a layer, so it has focus -
    // which is the whole reason the rule is worth having.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);

    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, &.{ .{ .dialog = 0 }, .{ .dialog = 1 } });
    try testing.expectEqual(TestId{ .dialog = 0 }, f.focused().?);
}

test "tab cannot escape an overlay" {
    // Tabbing out of a modal is how a user ends up typing into something they
    // cannot see, and then reports that the dialog "does nothing".
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, &.{ .{ .dialog = 0 }, .{ .dialog = 1 } });

    for (0..6) |_| {
        f.next();
        try testing.expect(f.focused().? == .dialog);
    }
}

test "closing an overlay hands the keyboard back where it was" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    f.next();
    f.next();
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);

    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, &.{.{ .dialog = 0 }});
    try testing.expectEqual(TestId{ .dialog = 0 }, f.focused().?);

    // Dismissed. Not back to the top of the list - back to where the user was.
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
}

test "focus on a control that stops being drawn is repaired" {
    // A list scrolls, a row is filtered away, a tab changes. The focused id
    // survives the frame and the control does not, and the symptom is a
    // keyboard that stops answering with nothing drawn wrong.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 7 } }, null);
    f.set(.{ .button = 7 });
    try testing.expectEqual(TestId{ .button = 7 }, f.focused().?);

    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 8 } }, null);
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "a frame with nothing focusable leaves nothing focused" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{.{ .field = 0 }}, null);
    drawFrame(&f, &.{}, null);
    try testing.expectEqual(@as(?TestId, null), f.focused());
    // And moving focus over an empty registry does nothing rather than trap.
    f.next();
    f.prev();
    try testing.expectEqual(@as(?TestId, null), f.focused());
}

test "setting focus to something undrawn is ignored" {
    // The id comes from a click, an action, a restored session. Accepting one
    // that was never drawn strands the keyboard on a control that cannot be
    // seen or reached.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    f.set(.{ .button = 99 });
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "focus buried under an overlay is remembered, not lost" {
    // The distinction from the repair case: the control is still drawn, just
    // underneath. Forgetting it here is what makes a dialog dismiss feel like
    // it reset the screen.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 5 } }, null);
    f.set(.{ .button = 5 });

    for (0..3) |_| {
        drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 5 } }, &.{.{ .dialog = 0 }});
    }
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 5 } }, null);
    try testing.expectEqual(TestId{ .button = 5 }, f.focused().?);
}

test "has answers for the focus ring" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    try testing.expect(f.has(.{ .field = 0 }));
    try testing.expect(!f.has(.{ .button = 1 }));
}

test "focus starts where the client says, not where drawing happened to begin" {
    // The damage this prevents is specific: a sidebar draws its search box
    // first, so the application opens with the keyboard inside a text field,
    // every single letter shortcut is dead, and nothing on screen says why.
    var f: TestFocus = .{ .initial = .{ .button = 1 } };
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    try testing.expectEqual(TestId{ .button = 1 }, f.focused().?);

    // Only a starting point. Once the user moves, it stops applying.
    f.next();
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
}

test "a starting point that is not drawn falls back rather than stranding" {
    var f: TestFocus = .{ .initial = .{ .button = 99 } };
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "an overlay still wins over the starting point" {
    // The rule that focus lives in the top layer is not negotiable by a
    // preference expressed for the base layer.
    var f: TestFocus = .{ .initial = .{ .button = 1 } };
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, &.{.{ .dialog = 0 }});
    try testing.expectEqual(TestId{ .dialog = 0 }, f.focused().?);
}
