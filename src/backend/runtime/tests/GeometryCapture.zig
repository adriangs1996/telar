const Trace = @import("Trace.zig");
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneResizeGeometryLease = @import("../application/commands/PaneResizeGeometryLease.zig");
const GeometryCapture = @This();

trace: *Trace,
attachments: *AttachmentStoreType,
holds_result: bool = true,
holds_calls: usize = 0,
release_calls: usize = 0,
checked_workspace: ?WorkspaceLocationType = null,
released_workspace: ?WorkspaceLocationType = null,
release_saw_empty_store: bool = false,
release_saw_departed_workspace: bool = false,

pub fn lease(capture: *GeometryCapture) PaneResizeGeometryLease {
    return .{
        .context = capture,
        .holds = holds,
        .release = release,
    };
}

fn holds(context: *anyopaque, workspace: WorkspaceLocationType) bool {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.geometry_check);
    capture.holds_calls += 1;
    capture.checked_workspace = workspace;
    return capture.holds_result;
}

fn release(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.geometry_release);
    capture.release_calls += 1;
    capture.released_workspace = workspace;
    capture.release_saw_empty_store = capture.attachments.len() == 0;
    capture.release_saw_departed_workspace = capture.attachments.currentWorkspace() == null;
}
