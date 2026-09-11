const Bookmark = @import("Bookmark.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PlanWorkspaceArrivalHandler = @import("PlanWorkspaceArrivalHandler.zig");
const Capture = @This();

bookmark: ?Bookmark = null,
calls: usize = 0,
workspace: ?WorkspaceLocationType = null,

pub fn handler(capture: *Capture) PlanWorkspaceArrivalHandler {
    return .{ .bookmarks = .{
        .context = capture,
        .find = find,
    } };
}

fn find(context: *anyopaque, workspace: WorkspaceLocationType) ?Bookmark {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.workspace = workspace;

    return capture.bookmark;
}
