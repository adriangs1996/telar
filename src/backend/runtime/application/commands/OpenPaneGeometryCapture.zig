const GeometryCapture = @This();
const GeometryLease = @import("OpenPaneGeometryLease.zig");
const source_namespace = @import("open_pane.zig");
available: bool = true,
acquire_count: usize = 0,
release_count: usize = 0,

pub fn port(capture: *GeometryCapture) GeometryLease {
    return .{
        .context = capture,
        .acquire = acquire,
        .release = release,
    };
}

fn acquire(context: *anyopaque, _: source_namespace.schema.WorkspaceLocation) bool {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.acquire_count += 1;
    return capture.available;
}

fn release(context: *anyopaque, _: source_namespace.schema.WorkspaceLocation) void {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.release_count += 1;
}
