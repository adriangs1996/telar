const Source = @import("Source.zig");
const TabSnapshotRequest = @import("TabSnapshotRequest.zig");
const TabSnapshotResult = @import("TabSnapshotResult.zig");
const TabSnapshotExecutor = @import("TabSnapshotExecutor.zig");
const Handler = @This();

source: Source,

/// Returns a snapshot reference only while both its tab and at least one
/// running pane exist. The later encoder owns materializing pane details.
///
/// ```zig
/// const snapshot = try handler.execute(.{ .location = location });
/// ```
pub fn execute(handler: *Handler, request: TabSnapshotRequest) !TabSnapshotResult {
    if (!handler.source.contains_tab(handler.source.context, request.location)) {
        return error.TabNotFound;
    }

    if (handler.source.running_panes(handler.source.context, request.location) == 0) {
        return error.TabNotFound;
    }

    return .{ .location = request.location };
}

/// Exposes this handler through the query interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *Handler) TabSnapshotExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, request: TabSnapshotRequest) !TabSnapshotResult {
    const handler: *Handler = @ptrCast(@alignCast(context));
    return handler.execute(request);
}
