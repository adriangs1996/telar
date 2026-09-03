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

/// Who has the keyboard.
///
/// The naive version of this is a field on the application saying which dialog
/// is open, and a check for it at the top of every key handler. That survives
/// one overlay. With two it becomes a chain of conditions that has to be
/// repeated identically in every branch, and the bug it produces is a UI that
/// looks focused and does not respond - the worst kind, because nothing is
/// drawn wrong.
///
/// So focus is registered the same way clicks are: while drawing, in a layer.
/// One rule then replaces every one of those checks:
///
///   **Focus lives in the topmost layer that registered anything focusable.**
///
/// A dialog opening takes the keyboard because it opened a layer. A dialog
/// closing gives it back because its layer is gone. Neither is code anybody
/// writes; both fall out of where the controls were registered.
///
/// Registrations are rebuilt every frame and the focused id is not, which is
/// the whole subtlety. `endFrame` is what reconciles them.
pub fn Focus(comptime Id: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const max_layers = 8;

        pub const Entry = struct { id: Id, layer: u8 };

        entries: [capacity]Entry = undefined,
        len: usize = 0,
        layer: u8 = 0,
        top: u8 = 0,

        /// Survives the frame, unlike the registrations.
        current: ?Id = null,

        /// Where focus starts, before the user has moved it.
        ///
        /// Without this, focus lands on whatever happened to draw first, and
        /// drawing order is a layout decision rather than an interaction one.
        /// The concrete damage: a sidebar whose search box is drawn at the top
        /// opens with the keyboard inside a text field, which makes every
        /// single letter shortcut in the application dead until the user
        /// presses Tab - and nothing on screen explains why.
        initial: ?Id = null,
        /// Where focus was when each layer last had it, so dismissing a dialog
        /// returns the keyboard to the control the user left rather than to the
        /// top of the list.
        remembered: [max_layers]?Id = @splat(null),

        pub fn beginFrame(f: *Self) void {
            f.len = 0;
            f.layer = 0;
            f.top = 0;
        }

        pub fn beginLayer(f: *Self) void {
            if (f.layer + 1 >= max_layers) {
                return;
            }
            f.layer += 1;
            f.top = @max(f.top, f.layer);
        }

        pub fn endLayer(f: *Self) void {
            if (f.layer == 0) {
                return;
            }
            f.layer -= 1;
        }

        /// Declares that `id` can hold the keyboard. Order is tab order.
        pub fn register(f: *Self, id: Id) void {
            if (f.len == capacity) {
                return;
            }
            f.entries[f.len] = .{ .id = id, .layer = f.layer };
            f.len += 1;
        }

        /// Reconciles the surviving focus with what was actually drawn.
        ///
        /// Two things go wrong without it, and both look like a dead keyboard:
        /// the focused control stopped being drawn (a dialog closed, a list
        /// scrolled), or a new layer appeared and focus stayed underneath it.
        pub fn endFrame(f: *Self) void {
            if (f.len == 0) {
                f.current = null;
                return;
            }
            if (f.current) |id| {
                if (f.layerOf(id)) |layer| {
                    if (layer == f.top) {
                        return;
                    }
                    // Focus is valid but buried. Remember where, so closing
                    // whatever covered it puts the keyboard back.
                    f.remembered[layer] = id;
                }
            }
            // Prefer where this layer was left, then the declared starting
            // point, then whatever drew first.
            if (f.remembered[f.top]) |id| {
                if (f.layerOf(id)) |layer| {
                    if (layer == f.top) {
                        f.current = id;
                        return;
                    }
                }
            }
            if (f.initial) |id| {
                if (f.layerOf(id)) |layer| {
                    if (layer == f.top) {
                        f.current = id;
                        return;
                    }
                }
            }
            f.current = f.firstIn(f.top);
        }

        pub fn focused(f: *const Self) ?Id {
            return f.current;
        }

        /// Whether `id` holds the keyboard, for drawing a focus ring.
        pub fn has(f: *const Self, id: Id) bool {
            const current = f.current orelse return false;
            return std.meta.eql(current, id);
        }

        /// Moves focus explicitly - a click on a control, or an action that
        /// puts the keyboard somewhere. Ignored for anything not drawn, so a
        /// stale id cannot strand the keyboard.
        pub fn set(f: *Self, id: Id) void {
            if (f.layerOf(id)) |layer| {
                f.remembered[layer] = id;
                f.current = id;
            }
        }

        pub fn next(f: *Self) void {
            f.step(1);
        }

        pub fn prev(f: *Self) void {
            f.step(-1);
        }

        /// Cycles within the top layer, wrapping.
        ///
        /// Confined to one layer on purpose: tabbing out of a modal into the
        /// list behind it is how a user ends up typing into something they
        /// cannot see.
        fn step(f: *Self, delta: i32) void {
            const count = f.countIn(f.top);
            if (count == 0) {
                return;
            }

            const at = f.indexIn(f.top, f.current) orelse {
                f.current = f.firstIn(f.top);
                return;
            };
            const size: i32 = @intCast(count);
            const moved = @mod(@as(i32, @intCast(at)) + delta + size, size);
            f.current = f.nthIn(f.top, @intCast(moved));
            if (f.current) |id| {
                f.remembered[f.top] = id;
            }
        }

        fn layerOf(f: *const Self, id: Id) ?u8 {
            for (f.entries[0..f.len]) |entry| {
                if (std.meta.eql(entry.id, id)) {
                    return entry.layer;
                }
            }
            return null;
        }

        fn countIn(f: *const Self, layer: u8) usize {
            var total: usize = 0;
            for (f.entries[0..f.len]) |entry| {
                if (entry.layer == layer) {
                    total += 1;
                }
            }
            return total;
        }

        fn firstIn(f: *const Self, layer: u8) ?Id {
            return f.nthIn(layer, 0);
        }

        fn nthIn(f: *const Self, layer: u8, n: usize) ?Id {
            var seen: usize = 0;
            for (f.entries[0..f.len]) |entry| {
                if (entry.layer != layer) {
                    continue;
                }
                if (seen == n) {
                    return entry.id;
                }
                seen += 1;
            }
            return null;
        }

        fn indexIn(f: *const Self, layer: u8, id: ?Id) ?usize {
            const wanted = id orelse return null;
            var seen: usize = 0;
            for (f.entries[0..f.len]) |entry| {
                if (entry.layer != layer) {
                    continue;
                }
                if (std.meta.eql(entry.id, wanted)) {
                    return seen;
                }
                seen += 1;
            }
            return null;
        }
    };
}

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
