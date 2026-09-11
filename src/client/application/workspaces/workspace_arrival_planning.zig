//! Application policy for constructing one confirmed workspace arrival.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;
const pane_open_delivery = @import("../panes/root.zig").pane_open_delivery;

pub const layout_mod = workspace_capability.layout;
pub const schema = core.schema;

pub const Bookmark = @import("Bookmark.zig");

pub const Bookmarks = @import("WorkspaceArrivalPlanningBookmarks.zig");

pub const PlanWorkspaceArrivalHandler = @import("PlanWorkspaceArrivalHandler.zig");

const Capture = @import("WorkspaceArrivalPlanningCapture.zig");

const testing_location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(3) },
    .tab_id = @enumFromInt(5),
};

const testing_opened: pane_open_delivery.OpenedPane = .{
    .pane_id = @enumFromInt(7),
    .location = testing_location,
    .created = false,
};

const testing_size: schema.TerminalSize = .{ .cols = 80, .rows = 24 };

test "PlanWorkspaceArrivalHandler constructs an arrival without a bookmark" {
    var capture: Capture = .{};
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
    var layout: layout_mod.Layout = .{};
    try layout.addRoot(testing_opened.pane_id);
    var capture: Capture = .{ .bookmark = .{
        .location = testing_location,
        .tab_layout = layout,
    } };
    const handler = capture.handler();

    const arrival = handler.execute(testing_opened, testing_size);

    try std.testing.expectEqualDeep(layout, arrival.saved_layout.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "PlanWorkspaceArrivalHandler rejects a layout from another tab" {
    var layout: layout_mod.Layout = .{};
    try layout.addRoot(testing_opened.pane_id);
    var stale = testing_location;
    stale.tab_id = @enumFromInt(9);
    var capture: Capture = .{ .bookmark = .{
        .location = stale,
        .tab_layout = layout,
    } };
    const handler = capture.handler();

    const arrival = handler.execute(testing_opened, testing_size);

    try std.testing.expect(arrival.saved_layout == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
