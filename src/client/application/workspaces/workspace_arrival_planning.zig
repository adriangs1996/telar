//! Application policy for constructing one confirmed workspace arrival.

const TabLocationType = @import("telar-core").TabLocation;
const OpenedPaneType = @import("../panes/OpenedPane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const WorkspaceArrivalPlanningCapture = @import("WorkspaceArrivalPlanningCapture.zig");
const std = @import("std");
const LayoutType = @import("../../workspace/WorkspaceLayout.zig");

const testing_location: TabLocationType = .{
    .workspace = .{ .workspace = @enumFromInt(3) },
    .tab_id = @enumFromInt(5),
};

const testing_opened: OpenedPaneType = .{
    .pane_id = @enumFromInt(7),
    .location = testing_location,
    .created = false,
};

const testing_size: TerminalSizeType = .{ .cols = 80, .rows = 24 };

test "PlanWorkspaceArrivalHandler constructs an arrival without a bookmark" {
    var capture: WorkspaceArrivalPlanningCapture = .{};
    const handler = capture.handler();

    const arrival = handler.execute(testing_opened, testing_size);

    try std.testing.expectEqual(testing_opened.pane_id, arrival.pane_id);
    try std.testing.expectEqualDeep(testing_location, arrival.location);
    try std.testing.expectEqualDeep(testing_size, arrival.size);
    try std.testing.expect(arrival.saved_layout == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing_location.workspace, capture.workspace.?);
}

test "PlanWorkspaceArrivalHandler retains an exact bookmarked layout" {
    var layout: LayoutType = .{};
    try layout.addRoot(testing_opened.pane_id);
    var capture: WorkspaceArrivalPlanningCapture = .{ .bookmark = .{
        .location = testing_location,
        .tab_layout = layout,
    } };
    const handler = capture.handler();

    const arrival = handler.execute(testing_opened, testing_size);

    try std.testing.expectEqualDeep(layout, arrival.saved_layout.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "PlanWorkspaceArrivalHandler rejects a layout from another tab" {
    var layout: LayoutType = .{};
    try layout.addRoot(testing_opened.pane_id);
    var stale = testing_location;
    stale.tab_id = @enumFromInt(9);
    var capture: WorkspaceArrivalPlanningCapture = .{ .bookmark = .{
        .location = stale,
        .tab_layout = layout,
    } };
    const handler = capture.handler();

    const arrival = handler.execute(testing_opened, testing_size);

    try std.testing.expect(arrival.saved_layout == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
