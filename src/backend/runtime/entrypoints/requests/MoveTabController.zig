const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const MoveTabExecutorType = @import("../../application/commands/MoveTabExecutor.zig");
const MoveTabType = @import("telar-core").MoveTab;
const RequestIdType = @import("telar-core").RequestId;
const MoveTabFailure = @import("MoveTabFailure.zig");
const Controller = @This();

responses: *ResponseQueueType,
move_tab: MoveTabExecutorType,

/// Creates a controller scoped to one runtime request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, move_tab: MoveTabExecutorType) Controller {
    return .{ .responses = responses, .move_tab = move_tab };
}

/// Maps the wire request into a command and returns either the canonical
/// committed position or one expected protocol failure.
///
/// ```zig
/// try controller.moveTab(request);
/// ```
pub fn moveTab(controller: *Controller, request: MoveTabType) !void {
    const moved = controller.move_tab.execute(.{
        .location = request.location,
        .direction = request.direction,
    }) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try controller.queueFailure(request.request_id, .{
                .code = .workspace_not_found,
                .message = "workspace not found",
            }),
            error.TabNotFound => try controller.queueFailure(request.request_id, .{
                .code = .tab_not_found,
                .message = "tab not found",
            }),
            else => return err,
        }

        return;
    };

    try controller.responses.push(.{ .tab_moved = .{
        .request_id = request.request_id,
        .location = moved.location,
        .position = moved.position,
    } });
}

fn queueFailure(controller: *Controller, request_id: RequestIdType, failure: MoveTabFailure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
