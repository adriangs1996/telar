const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const CreateWorkspaceGeometryLease = @import("CreateWorkspaceGeometryLease.zig");
const GeometryCapture = @This();

available: bool = true,
acquire_count: usize = 0,
release_count: usize = 0,
last_workspace: ?WorkspaceLocationType = null,

pub fn port(capture: *GeometryCapture) CreateWorkspaceGeometryLease {
    return .{
        .context = capture,
        .acquire = acquire,
        .release = release,
    };
}

fn acquire(context: *anyopaque, workspace: WorkspaceLocationType) bool {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.acquire_count += 1;
    capture.last_workspace = workspace;
    return capture.available;
}

fn release(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.release_count += 1;
    capture.last_workspace = workspace;
}
