const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ClosePaneExecutorType = @import("../../application/commands/ClosePaneExecutor.zig");
const ClosePaneType = @import("telar-core").ClosePane;
const Controller = @This();

responses: *ResponseQueueType,
close_pane: ClosePaneExecutorType,

/// Creates a controller scoped to one pane close request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, close_pane: ClosePaneExecutorType) Controller {
    return .{ .responses = responses, .close_pane = close_pane };
}

/// Maps authorization failures to the protocol. A successful request has
/// no acknowledgement; the later `pane_exited` message is authoritative.
///
/// ```zig
/// try controller.closePane(request);
/// ```
pub fn closePane(controller: *Controller, request: ClosePaneType) !void {
    _ = controller.close_pane.execute(.{ .pane_id = request.pane_id }) catch |err| {
        if (err == error.PaneNotAttached) {
            try controller.responses.push(.{ .request_failed = .{
                .request_id = request.request_id,
                .code = .pane_not_found,
                .message = "pane not attached",
            } });
            return;
        }

        return err;
    };
}
