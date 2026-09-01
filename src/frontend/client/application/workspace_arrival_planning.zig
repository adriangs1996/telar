//! Application policy for constructing one confirmed workspace arrival.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../model.zig");
const pane_open_delivery = @import("pane_open_delivery.zig");

const layout_mod = workspace_capability.layout;
const schema = core.schema;

pub const Bookmark = struct {
    location: schema.TabLocation,
    tab_layout: ?layout_mod.Layout,
};

pub const Bookmarks = struct {
    context: *anyopaque,
    find: *const fn (*anyopaque, schema.WorkspaceLocation) ?Bookmark,
};

pub const PlanWorkspaceArrivalHandler = struct {
    bookmarks: Bookmarks,

    /// Constructs one runtime-confirmed arrival and retains a saved layout
    /// only when its bookmark names the exact confirmed tab.
    ///
    /// ```zig
    /// const arrival = handler.execute(opened, requested_size);
    /// ```
    pub fn execute(handler: *const PlanWorkspaceArrivalHandler, opened: pane_open_delivery.OpenedPane, size: schema.TerminalSize) client_model.WorkspaceArrival {
        const bookmark = handler.bookmarks.find(
            handler.bookmarks.context,
            opened.location.workspace,
        );
        const saved_layout = if (bookmark) |remembered|
            if (std.meta.eql(remembered.location, opened.location)) remembered.tab_layout else null
        else
            null;

        return .{
            .pane_id = opened.pane_id,
            .location = opened.location,
            .size = size,
            .saved_layout = saved_layout,
        };
    }
};

const Capture = struct {
    bookmark: ?Bookmark = null,
    calls: usize = 0,
    workspace: ?schema.WorkspaceLocation = null,

    fn handler(capture: *Capture) PlanWorkspaceArrivalHandler {
        return .{ .bookmarks = .{
            .context = capture,
            .find = find,
        } };
    }

    fn find(context: *anyopaque, workspace: schema.WorkspaceLocation) ?Bookmark {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.workspace = workspace;

        return capture.bookmark;
    }
};

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
