//! What was clickable, and which layer it belonged to.
//!
//! In the library rather than in the client because a modal that swallows the
//! clicks underneath it is a property of the layering, not of the modal. A
//! widget cannot implement it: by the time the widget under the modal is asked,
//! the wrong answer has already been given.

const std = @import("std");
const Rect = @import("telar-core").ui.Rect;

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

/// What was clickable, and which layer it belonged to.
///
/// Generic over the action so this can live down here rather than in the
/// client: a modal that swallows the clicks underneath it is a property of the
/// layering, not of the modal. A widget cannot implement it - by the time the
/// widget under the modal is asked, the decision has already been made wrong.
///
/// Fixed capacity on purpose. A frame wanting more clickable things than this
/// has a layout problem, and dropping the extras beats allocating on the draw
/// path.
pub fn Hits(comptime Action: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// Base, dropdown, modal, tooltip. Deeper stacks are a UI that has
        /// lost track of what the user is looking at.
        pub const max_layers = 8;

        pub const Entry = struct { rect: Rect, action: Action, layer: u8 };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        /// Where each layer stops clicks from falling through. Null means the
        /// layer is transparent outside its own registrations, which is what
        /// the base layer and a tooltip both want.
        blocks: [max_layers]?Rect = @splat(null),
        layer: u8 = 0,
        /// The deepest layer opened this frame, so `at` knows where to start.
        top: u8 = 0,

        /// Everything registered this frame, oldest first.
        ///
        /// Exposed because the useful test over a hit registry is an
        /// exhaustiveness one - every variant a UI can produce should appear
        /// somewhere in a drawn frame, and a control that is drawn but never
        /// registered is invisible to every other kind of test.
        pub fn registered(h: *const Self) []const Entry {
            return h.entries[0..h.len];
        }

        pub fn clear(h: *Self) void {
            h.len = 0;
            h.layer = 0;
            h.top = 0;
            h.blocks = @splat(null);
        }

        /// Opens a layer above the current one.
        ///
        /// `swallows` is the region in which this layer answers for every
        /// point, registered or not. A modal passes its own frame, so a click
        /// on its blank interior lands on the modal instead of reaching the
        /// list behind it. Pass null for an overlay that should not steal
        /// clicks it has no control under - a tooltip, a drag ghost.
        pub fn beginLayer(h: *Self, swallows: ?Rect) void {
            if (h.layer + 1 >= max_layers) {
                return;
            }
            h.layer += 1;
            h.top = @max(h.top, h.layer);
            h.blocks[h.layer] = swallows;
        }

        pub fn endLayer(h: *Self) void {
            if (h.layer == 0) {
                return;
            }
            h.layer -= 1;
        }

        pub fn add(h: *Self, rect: Rect, action: Action) void {
            if (h.len == capacity) {
                return;
            }
            if (rect.isEmpty()) {
                return;
            }
            h.entries[h.len] = .{ .rect = rect, .action = action, .layer = h.layer };
            h.len += 1;
        }

        /// What a click at (x, y) hits, if anything.
        ///
        /// Top layer down, and within a layer the newest registration wins -
        /// so a chip drawn over a task row takes the click rather than the row
        /// underneath it. A layer that swallows the point ends the search
        /// there even when it registered nothing at it, which is the whole
        /// difference between an overlay and a modal.
        pub fn at(h: *const Self, x: u16, y: u16) ?Action {
            var layer: i16 = h.top;
            while (layer >= 0) : (layer -= 1) {
                const current: u8 = @intCast(layer);
                var index = h.len;
                while (index > 0) {
                    index -= 1;
                    const entry = h.entries[index];
                    if (entry.layer != current) {
                        continue;
                    }
                    if (entry.rect.contains(x, y)) {
                        return entry.action;
                    }
                }
                if (h.blocks[current]) |region| {
                    if (region.contains(x, y)) {
                        return null;
                    }
                }
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestAction = union(enum) { row: u16, button, dismiss };

const TestHits = Hits(TestAction, 32);

test "within a layer the newest registration wins" {
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 20, .h = 1 }, .{ .row = 3 });
    // A chip drawn on top of the row it belongs to.
    h.add(.{ .x = 5, .y = 0, .w = 4, .h = 1 }, .button);

    try testing.expectEqual(TestAction.button, h.at(6, 0).?);
    try testing.expectEqual(TestAction{ .row = 3 }, h.at(1, 0).?);
}

test "a modal swallows clicks on its blank interior" {
    // The failure this exists to prevent: a dialog opens over a list, the user
    // clicks the dialog's empty background, and the list behind it selects a
    // row. Nothing the dialog draws can fix that, because by the time the row
    // is asked the decision has already been made.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    const frame: Rect = .{ .x = 10, .y = 5, .w = 20, .h = 8 };
    h.beginLayer(frame);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    // The modal's own control.
    try testing.expectEqual(TestAction.button, h.at(13, 10).?);
    // Its blank interior: swallowed, not passed down.
    try testing.expectEqual(@as(?TestAction, null), h.at(25, 6));
    // Outside it, the list is still live.
    try testing.expectEqual(TestAction{ .row = 7 }, h.at(2, 2).?);
}

test "a modal can claim the whole screen to catch a click outside itself" {
    // How "click anywhere else to dismiss" is built: the layer swallows
    // everything, and the outside is registered rather than left to fall
    // through.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    h.beginLayer(.{ .x = 0, .y = 0, .w = 40, .h = 20 });
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .dismiss);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    try testing.expectEqual(TestAction.button, h.at(13, 10).?);
    try testing.expectEqual(TestAction.dismiss, h.at(2, 2).?);
}

test "a transparent overlay lets clicks through" {
    // A tooltip is drawn above everything and controls nothing. Swallowing
    // clicks under it would make the UI go dead wherever a hint happens to be.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    h.beginLayer(null);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    try testing.expectEqual(TestAction.button, h.at(13, 10).?);
    try testing.expectEqual(TestAction{ .row = 7 }, h.at(25, 6).?);
}

test "layers nest and unwind" {
    // A dropdown inside a modal: the innermost layer answers first, and
    // closing it hands the modal back its clicks rather than the base.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 1 });

    h.beginLayer(.{ .x = 5, .y = 5, .w = 30, .h = 10 });
    h.add(.{ .x = 6, .y = 6, .w = 4, .h = 1 }, .button);

    h.beginLayer(.{ .x = 8, .y = 7, .w = 10, .h = 4 });
    h.add(.{ .x = 9, .y = 8, .w = 3, .h = 1 }, .dismiss);
    h.endLayer();

    h.endLayer();

    try testing.expectEqual(TestAction.dismiss, h.at(10, 8).?);
    // Inside the dropdown but not on its item: the dropdown keeps it.
    try testing.expectEqual(@as(?TestAction, null), h.at(16, 9));
    // Inside the modal, outside the dropdown: the modal's control still works.
    try testing.expectEqual(TestAction.button, h.at(7, 6).?);
    // Outside everything.
    try testing.expectEqual(TestAction{ .row = 1 }, h.at(1, 1).?);
}

test "clearing forgets the layers as well as the entries" {
    // Layers are opened while drawing, and a frame that returns early leaves
    // the stack deep. Carrying that into the next frame would make the base
    // layer start life underneath a modal that no longer exists.
    var h: TestHits = .{};
    h.beginLayer(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    h.add(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .button);

    h.clear();
    h.add(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{ .row = 0 });
    try testing.expectEqual(TestAction{ .row = 0 }, h.at(1, 0).?);
    try testing.expectEqual(@as(?TestAction, null), h.at(6, 6));
}
