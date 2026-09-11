const GeometryCapture = @This();
const Trace = @import("Trace.zig");
const source_namespace = @import("pane_resize_test.zig");
const pane_resize_commands = @import("../application/commands/pane_resize.zig");
trace: *Trace,
attachments: *source_namespace.AttachmentStore,
holds_result: bool = true,
holds_calls: usize = 0,
release_calls: usize = 0,
checked_workspace: ?source_namespace.schema.WorkspaceLocation = null,
released_workspace: ?source_namespace.schema.WorkspaceLocation = null,
release_saw_empty_store: bool = false,
release_saw_departed_workspace: bool = false,

pub fn lease(capture: *GeometryCapture) pane_resize_commands.GeometryLease {
    return .{
        .context = capture,
        .holds = holds,
        .release = release,
    };
}

fn holds(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) bool {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.geometry_check);
    capture.holds_calls += 1;
    capture.checked_workspace = workspace;
    return capture.holds_result;
}

fn release(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) void {
    const capture: *GeometryCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.geometry_release);
    capture.release_calls += 1;
    capture.released_workspace = workspace;
    capture.release_saw_empty_store = capture.attachments.len() == 0;
    capture.release_saw_departed_workspace = capture.attachments.currentWorkspace() == null;
}
