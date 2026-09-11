const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const TabSnapshotExecutor = @import("../../application/queries/TabSnapshotExecutor.zig");
const RequestTabSnapshotType = @import("telar-core").RequestTabSnapshot;
const Controller = @This();

responses: *ResponseQueueType,
query: TabSnapshotExecutor,

/// Creates a controller scoped to one tab-snapshot request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, query: TabSnapshotExecutor) Controller {
    return .{ .responses = responses, .query = query };
}

/// Maps a wire request to the tab query and queues its canonical response
/// or a `tab_not_found` failure.
///
/// ```zig
/// try controller.requestTabSnapshot(request);
/// ```
pub fn requestTabSnapshot(controller: *Controller, request: RequestTabSnapshotType) !void {
    const snapshot = controller.query.execute(.{ .location = request.location }) catch |err| {
        if (err == error.TabNotFound) {
            try controller.responses.push(.{ .request_failed = .{
                .request_id = request.request_id,
                .code = .tab_not_found,
                .message = "tab not found",
            } });
            return;
        }

        return err;
    };

    try controller.responses.push(.{ .tab_snapshot = .{
        .request_id = request.request_id,
        .location = snapshot.location,
    } });
}
