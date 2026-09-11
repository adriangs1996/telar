//! Application command for requesting an attached pane to close.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const ClosePane = @import("ClosePane.zig");

pub const ClosePaneResult = @import("ClosePaneResult.zig");

pub const AttachedPaneCloser = @import("AttachedPaneCloser.zig");

pub const ClosePaneExecutor = @import("ClosePaneExecutor.zig");

pub const ClosePaneHandler = @import("ClosePaneHandler.zig");

const PaneCapture = @import("ClosePanePaneCapture.zig");

test "ClosePaneHandler returns the exact attached pane transition" {
    const pane_id = try schema.id.pane(7);

    for ([_]bool{ true, false }) |newly_requested| {
        var panes: PaneCapture = .{ .result = newly_requested };
        var handler: ClosePaneHandler = .{ .panes = panes.port() };

        const result = try handler.executor().execute(.{ .pane_id = pane_id });

        try std.testing.expectEqual(@as(usize, 1), panes.call_count);
        try std.testing.expectEqual(pane_id, panes.last_pane_id);
        try std.testing.expectEqual(pane_id, result.pane_id);
        try std.testing.expectEqual(newly_requested, result.newly_requested);
    }
}

test "ClosePaneHandler rejects panes outside the requesting attachments" {
    var panes: PaneCapture = .{ .result = null };
    var handler: ClosePaneHandler = .{ .panes = panes.port() };
    const pane_id = try schema.id.pane(7);

    try std.testing.expectError(error.PaneNotAttached, handler.execute(.{
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), panes.call_count);
    try std.testing.expectEqual(pane_id, panes.last_pane_id);
}
