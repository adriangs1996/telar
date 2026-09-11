//! Application policy for restoring the visible active tab after a local
//! workspace-handoff effect fails before departure commits.

const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceHandoffRestorationTestingModel = @import("WorkspaceHandoffRestorationTestingModel.zig");
const WorkspaceHandoffRestorationCapture = @import("WorkspaceHandoffRestorationCapture.zig");
const std = @import("std");

pub const Outcome = enum {
    no_active_tab,
    snapshot_coalesced,
    snapshot_requested,
};

pub const Event = union(enum) {
    show_graphics: PaneIdType,
    snapshot_pending,
    request_snapshot: TabLocationType,
};

pub const Failure = enum {
    none,
    sibling_graphics,
    snapshot,
};

test "RestoreWorkspaceHandoffHandler shows only active panes before snapshot recovery" {
    var testing = try WorkspaceHandoffRestorationTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceHandoffRestorationCapture = .{ .sibling = testing.sibling };
    var handler = capture.handler();
    const version = testing.model.version();

    const outcome = try handler.execute(testing.model);

    try std.testing.expectEqual(Outcome.snapshot_requested, outcome);
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = testing.root },
        .{ .show_graphics = testing.sibling },
        .snapshot_pending,
        .{ .request_snapshot = testing.active },
    }, capture.eventSlice());
    for (capture.eventSlice()) |event| switch (event) {
        .show_graphics => |pane_id| try std.testing.expect(pane_id != testing.inactive_pane),
        .snapshot_pending, .request_snapshot => {},
    };
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "RestoreWorkspaceHandoffHandler coalesces only after restoring graphics" {
    var testing = try WorkspaceHandoffRestorationTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceHandoffRestorationCapture = .{
        .sibling = testing.sibling,
        .pending = true,
    };
    var handler = capture.handler();

    const outcome = try handler.execute(testing.model);

    try std.testing.expectEqual(Outcome.snapshot_coalesced, outcome);
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = testing.root },
        .{ .show_graphics = testing.sibling },
        .snapshot_pending,
    }, capture.eventSlice());
}

test "RestoreWorkspaceHandoffHandler ignores an already empty model" {
    var testing = try WorkspaceHandoffRestorationTestingModel.init();
    defer testing.deinit();
    _ = testing.model.departWorkspace();
    var capture: WorkspaceHandoffRestorationCapture = .{ .sibling = testing.sibling };
    var handler = capture.handler();

    const outcome = try handler.execute(testing.model);

    try std.testing.expectEqual(Outcome.no_active_tab, outcome);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "RestoreWorkspaceHandoffHandler preserves completed stages on failure" {
    var graphics = try WorkspaceHandoffRestorationTestingModel.init();
    defer graphics.deinit();
    var graphics_capture: WorkspaceHandoffRestorationCapture = .{
        .sibling = graphics.sibling,
        .failure = .sibling_graphics,
    };
    var graphics_handler = graphics_capture.handler();

    try std.testing.expectError(error.GraphicsVisibilityFailed, graphics_handler.execute(graphics.model));
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = graphics.root },
        .{ .show_graphics = graphics.sibling },
    }, graphics_capture.eventSlice());

    var snapshot = try WorkspaceHandoffRestorationTestingModel.init();
    defer snapshot.deinit();
    var snapshot_capture: WorkspaceHandoffRestorationCapture = .{
        .sibling = snapshot.sibling,
        .failure = .snapshot,
    };
    var snapshot_handler = snapshot_capture.handler();

    try std.testing.expectError(error.SnapshotRequestFailed, snapshot_handler.execute(snapshot.model));
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = snapshot.root },
        .{ .show_graphics = snapshot.sibling },
        .snapshot_pending,
        .{ .request_snapshot = snapshot.active },
    }, snapshot_capture.eventSlice());
}
