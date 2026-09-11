const OpenPaneGeometryLease = @import("OpenPaneGeometryLease.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const GeometryCapture = @This();

available: bool = true,
acquire_count: usize = 0,
release_count: usize = 0,

pub fn port(capture: *GeometryCapture) OpenPaneGeometryLease {
    return .{
        .context = capture,
        .acquire = acquire,
        .release = release,
    };
}

fn acquire(context: *anyopaque, _: WorkspaceLocationType) bool {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.acquire_count += 1;
    return capture.available;
}

fn release(context: *anyopaque, _: WorkspaceLocationType) void {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.release_count += 1;
}
