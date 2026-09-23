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

        pub fn beginFrame(self: *Self) void {
            self.len = 0;
            self.layer = 0;
            self.top = 0;
        }

        pub fn beginLayer(self: *Self) void {
            if (self.layer + 1 >= max_layers) {
                return;
            }
            self.layer += 1;
            self.top = @max(self.top, self.layer);
        }

        pub fn endLayer(self: *Self) void {
            if (self.layer == 0) {
                return;
            }
            self.layer -= 1;
        }

        /// Declares that `id` can hold the keyboard. Order is tab order.
        pub fn register(self: *Self, id: Id) void {
            if (self.len == capacity) {
                return;
            }
            self.entries[self.len] = .{ .id = id, .layer = self.layer };
            self.len += 1;
        }

        /// Reconciles the surviving focus with what was actually drawn.
        ///
        /// Two things go wrong without it, and both look like a dead keyboard:
        /// the focused control stopped being drawn (a dialog closed, a list
        /// scrolled), or a new layer appeared and focus stayed underneath it.
        pub fn endFrame(self: *Self) void {
            if (self.len == 0) {
                self.current = null;
                return;
            }
            if (self.current) |id| {
                if (self.layerOf(id)) |layer| {
                    if (layer == self.top) {
                        return;
                    }
                    // Focus is valid but buried. Remember where, so closing
                    // whatever covered it puts the keyboard back.
                    self.remembered[layer] = id;
                }
            }
            // Prefer where this layer was left, then the declared starting
            // point, then whatever drew first.
            if (self.remembered[self.top]) |id| {
                if (self.layerOf(id)) |layer| {
                    if (layer == self.top) {
                        self.current = id;
                        return;
                    }
                }
            }
            if (self.initial) |id| {
                if (self.layerOf(id)) |layer| {
                    if (layer == self.top) {
                        self.current = id;
                        return;
                    }
                }
            }
            self.current = self.firstIn(self.top);
        }

        pub fn focused(self: *const Self) ?Id {
            return self.current;
        }

        /// Whether `id` holds the keyboard, for drawing a focus ring.
        pub fn has(self: *const Self, id: Id) bool {
            const current = self.current orelse return false;
            return std.meta.eql(current, id);
        }

        /// Moves focus explicitly - a click on a control, or an action that
        /// puts the keyboard somewhere. Ignored for anything not drawn, so a
        /// stale id cannot strand the keyboard.
        pub fn set(self: *Self, id: Id) void {
            if (self.layerOf(id)) |layer| {
                self.remembered[layer] = id;
                self.current = id;
            }
        }

        pub fn next(self: *Self) void {
            self.step(1);
        }

        pub fn prev(self: *Self) void {
            self.step(-1);
        }

        /// Cycles within the top layer, wrapping.
        ///
        /// Confined to one layer on purpose: tabbing out of a modal into the
        /// list behind it is how a user ends up typing into something they
        /// cannot see.
        fn step(self: *Self, delta: i32) void {
            const count = self.countIn(self.top);
            if (count == 0) {
                return;
            }

            const at = self.indexIn(self.top, self.current) orelse {
                self.current = self.firstIn(self.top);
                return;
            };
            const size: i32 = @intCast(count);
            const moved = @mod(@as(i32, @intCast(at)) + delta + size, size);
            self.current = self.nthIn(self.top, @intCast(moved));
            if (self.current) |id| {
                self.remembered[self.top] = id;
            }
        }

        fn layerOf(self: *const Self, id: Id) ?u8 {
            for (self.entries[0..self.len]) |entry| {
                if (std.meta.eql(entry.id, id)) {
                    return entry.layer;
                }
            }
            return null;
        }

        fn countIn(self: *const Self, layer: u8) usize {
            var total: usize = 0;
            for (self.entries[0..self.len]) |entry| {
                if (entry.layer == layer) {
                    total += 1;
                }
            }
            return total;
        }

        fn firstIn(self: *const Self, layer: u8) ?Id {
            return self.nthIn(layer, 0);
        }

        fn nthIn(self: *const Self, layer: u8, n: usize) ?Id {
            var seen: usize = 0;
            for (self.entries[0..self.len]) |entry| {
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

        fn indexIn(self: *const Self, layer: u8, id: ?Id) ?usize {
            const wanted = id orelse return null;
            var seen: usize = 0;
            for (self.entries[0..self.len]) |entry| {
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
