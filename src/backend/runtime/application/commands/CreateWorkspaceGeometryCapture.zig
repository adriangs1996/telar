const GeometryCapture = @This();
const source_namespace = @import("create_workspace.zig");
const GeometryLease = @import("CreateWorkspaceGeometryLease.zig");
available: bool = true,
acquire_count: usize = 0,
release_count: usize = 0,
last_workspace: ?source_namespace.schema.WorkspaceLocation = null,

pub fn port(capture: *GeometryCapture) GeometryLease {
    return .{
        .context = capture,
        .acquire = acquire,
        .release = release,
    };
}

fn acquire(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) bool {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.acquire_count += 1;
    capture.last_workspace = workspace;
    return capture.available;
}

fn release(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) void {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.release_count += 1;
    capture.last_workspace = workspace;
}
