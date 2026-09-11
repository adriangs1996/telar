const Capture = @This();
const Bookmark = @import("Bookmark.zig");
const source_namespace = @import("workspace_arrival_planning.zig");
const PlanWorkspaceArrivalHandler = @import("PlanWorkspaceArrivalHandler.zig");
bookmark: ?Bookmark = null,
calls: usize = 0,
workspace: ?source_namespace.schema.WorkspaceLocation = null,

pub fn handler(capture: *Capture) PlanWorkspaceArrivalHandler {
    return .{ .bookmarks = .{
        .context = capture,
        .find = find,
    } };
}

fn find(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) ?Bookmark {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.workspace = workspace;

    return capture.bookmark;
}
