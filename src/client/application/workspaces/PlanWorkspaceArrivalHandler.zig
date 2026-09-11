const WorkspaceArrivalPlanningBookmarks = @import("WorkspaceArrivalPlanningBookmarks.zig");
const OpenedPaneType = @import("../panes/OpenedPane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const WorkspaceArrivalType = @import("../../model/WorkspaceArrival.zig");
const std = @import("std");
const PlanWorkspaceArrivalHandler = @This();

bookmarks: WorkspaceArrivalPlanningBookmarks,

/// Constructs one runtime-confirmed arrival and retains a saved layout
/// only when its bookmark names the exact confirmed tab.
///
/// ```zig
/// const arrival = handler.execute(opened, requested_size);
/// ```
pub fn execute(handler: *const PlanWorkspaceArrivalHandler, opened: OpenedPaneType, size: TerminalSizeType) WorkspaceArrivalType {
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
