const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PlanWorkspaceHandoffHandler = @import("PlanWorkspaceHandoffHandler.zig");
const Capture = @This();

pane_id: ?PaneIdType = null,
calls: usize = 0,
location: ?WorkspaceLocationType = null,

pub fn handler(capture: *Capture) PlanWorkspaceHandoffHandler {
    return .{ .bookmarks = .{
        .context = capture,
        .remembered_pane = rememberedPane,
    } };
}

fn rememberedPane(context: *anyopaque, location: WorkspaceLocationType) ?PaneIdType {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.location = location;

    return capture.pane_id;
}
