//! Application command for requesting an attached pane to close.

const pane_module = @import("telar-core").pane;
const ClosePaneCapture = @import("ClosePaneCapture.zig");
const ClosePaneHandler = @import("ClosePaneHandler.zig");
const std = @import("std");

test "ClosePaneHandler returns the exact attached pane transition" {
    const pane_id = try pane_module(7);

    for ([_]bool{ true, false }) |newly_requested| {
        var panes: ClosePaneCapture = .{ .result = newly_requested };
        var handler: ClosePaneHandler = .{ .panes = panes.port() };

        const result = try handler.executor().execute(.{ .pane_id = pane_id });

        try std.testing.expectEqual(@as(usize, 1), panes.call_count);
        try std.testing.expectEqual(pane_id, panes.last_pane_id);
        try std.testing.expectEqual(pane_id, result.pane_id);
        try std.testing.expectEqual(newly_requested, result.newly_requested);
    }
}

test "ClosePaneHandler rejects panes outside the requesting attachments" {
    var panes: ClosePaneCapture = .{ .result = null };
    var handler: ClosePaneHandler = .{ .panes = panes.port() };
    const pane_id = try pane_module(7);

    try std.testing.expectError(error.PaneNotAttached, handler.execute(.{
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), panes.call_count);
    try std.testing.expectEqual(pane_id, panes.last_pane_id);
}
