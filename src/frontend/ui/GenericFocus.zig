const std = @import("std");

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
pub fn Type(comptime Id: type, comptime capacity: usize) type {
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
