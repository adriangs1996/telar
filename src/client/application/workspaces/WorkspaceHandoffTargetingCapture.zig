const Capture = @This();
const source_namespace = @import("workspace_handoff_targeting.zig");
const PlanWorkspaceHandoffHandler = @import("PlanWorkspaceHandoffHandler.zig");
pane_id: ?source_namespace.schema.PaneId = null,
calls: usize = 0,
location: ?source_namespace.schema.WorkspaceLocation = null,

pub fn handler(capture: *Capture) PlanWorkspaceHandoffHandler {
    return .{ .bookmarks = .{
        .context = capture,
        .remembered_pane = rememberedPane,
    } };
}

fn rememberedPane(context: *anyopaque, location: source_namespace.schema.WorkspaceLocation) ?source_namespace.schema.PaneId {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.location = location;

    return capture.pane_id;
}
