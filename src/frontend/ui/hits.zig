//! What was clickable, and which layer it belonged to.
//!
//! In the library rather than in the client because a modal that swallows the
//! clicks underneath it is a property of the layering, not of the modal. A
//! widget cannot implement it: by the time the widget under the modal is asked,
//! the wrong answer has already been given.

const GenericHits = @import("GenericHits.zig").Type;
const std = @import("std");
const Rect = @import("telar-core").Rect;

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestAction = union(enum) { row: u16, button, dismiss };

const TestHits = GenericHits(TestAction, 32);

test "within a layer the newest registration wins" {
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 20, .h = 1 }, .{ .row = 3 });
    // A chip drawn on top of the row it belongs to.
    h.add(.{ .x = 5, .y = 0, .w = 4, .h = 1 }, .button);

    try std.testing.expectEqual(TestAction.button, h.at(6, 0).?);
    try std.testing.expectEqual(TestAction{ .row = 3 }, h.at(1, 0).?);
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
    try std.testing.expectEqual(TestAction.button, h.at(13, 10).?);
    // Its blank interior: swallowed, not passed down.
    try std.testing.expectEqual(@as(?TestAction, null), h.at(25, 6));
    // Outside it, the list is still live.
    try std.testing.expectEqual(TestAction{ .row = 7 }, h.at(2, 2).?);
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

    try std.testing.expectEqual(TestAction.button, h.at(13, 10).?);
    try std.testing.expectEqual(TestAction.dismiss, h.at(2, 2).?);
}

test "a transparent overlay lets clicks through" {
    // A tooltip is drawn above everything and controls nothing. Swallowing
    // clicks under it would make the UI go dead wherever a hint happens to be.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    h.beginLayer(null);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    try std.testing.expectEqual(TestAction.button, h.at(13, 10).?);
    try std.testing.expectEqual(TestAction{ .row = 7 }, h.at(25, 6).?);
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

    try std.testing.expectEqual(TestAction.dismiss, h.at(10, 8).?);
    // Inside the dropdown but not on its item: the dropdown keeps it.
    try std.testing.expectEqual(@as(?TestAction, null), h.at(16, 9));
    // Inside the modal, outside the dropdown: the modal's control still works.
    try std.testing.expectEqual(TestAction.button, h.at(7, 6).?);
    // Outside everything.
    try std.testing.expectEqual(TestAction{ .row = 1 }, h.at(1, 1).?);
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
    try std.testing.expectEqual(TestAction{ .row = 0 }, h.at(1, 0).?);
    try std.testing.expectEqual(@as(?TestAction, null), h.at(6, 6));
}
