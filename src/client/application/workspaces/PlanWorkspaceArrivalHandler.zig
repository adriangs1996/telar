const PlanWorkspaceArrivalHandler = @This();
const Bookmarks = @import("WorkspaceArrivalPlanningBookmarks.zig");
const pane_open_delivery = @import("../panes/root.zig").pane_open_delivery;
const source_namespace = @import("workspace_arrival_planning.zig");
const client_model = @import("../../root.zig").model;
const std = @import("std");
bookmarks: Bookmarks,

/// Constructs one runtime-confirmed arrival and retains a saved layout
/// only when its bookmark names the exact confirmed tab.
///
/// ```zig
/// const arrival = handler.execute(opened, requested_size);
/// ```
pub fn execute(handler: *const PlanWorkspaceArrivalHandler, opened: pane_open_delivery.OpenedPane, size: source_namespace.schema.TerminalSize) client_model.WorkspaceArrival {
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
