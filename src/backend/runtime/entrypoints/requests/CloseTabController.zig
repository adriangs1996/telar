const Controller = @This();
const source_namespace = @import("close_tab.zig");
const close_tab_commands = @import("../../application/commands/close_tab.zig");
responses: *source_namespace.ResponseQueue,
close_tab: close_tab_commands.CloseTabExecutor,

/// Creates one controller for the lifetime of a close-tab request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, close_tab: close_tab_commands.CloseTabExecutor) Controller {
    return .{ .responses = responses, .close_tab = close_tab };
}

/// Translates the wire request into an application command and queues the
/// canonical removal result or one expected protocol failure.
///
/// ```zig
/// try controller.closeTab(request);
/// ```
pub fn closeTab(controller: *Controller, request: source_namespace.schema.CloseTab) !void {
    const removed = controller.close_tab.execute(.{ .location = request.location }) catch |err| {
        switch (err) {
            error.TabNotFound => try controller.queueTabNotFound(request.request_id),
            else => return err,
        }

        return;
    };

    try controller.responses.push(.{ .tab_closed = .{
        .request_id = request.request_id,
        .location = removed.location,
        .workspace_closed = removed.workspace_removed,
        .previous_workspace = removed.previous_workspace,
    } });
}

fn queueTabNotFound(controller: *Controller, request_id: source_namespace.schema.RequestId) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    } });
}
