const Controller = @This();
const source_namespace = @import("rename_tab.zig");
const rename_tab_commands = @import("../../application/commands/rename_tab.zig");
const Failure = @import("RenameTabFailure.zig");
responses: *source_namespace.ResponseQueue,
rename_tab: rename_tab_commands.RenameTabExecutor,

/// Creates one controller for the lifetime of a runtime request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, rename_tab: rename_tab_commands.RenameTabExecutor) Controller {
    return .{ .responses = responses, .rename_tab = rename_tab };
}

/// Translates a wire rename request into an application command and maps
/// its result or domain error back into one client response.
///
/// ```zig
/// try controller.renameTab(request);
/// ```
pub fn renameTab(controller: *Controller, request: source_namespace.schema.RenameTab) !void {
    const renamed = controller.rename_tab.execute(.{
        .location = request.location,
        .label = request.label,
    }) catch |err| {
        switch (err) {
            error.TabNotFound => try controller.queueFailure(request.request_id, .{
                .code = .tab_not_found,
                .message = "tab not found",
            }),
            error.InvalidTabLabel => try controller.queueFailure(request.request_id, .{
                .code = .invalid_request,
                .message = "invalid tab label",
            }),
            else => return err,
        }

        return;
    };

    const label = renamed.labelSlice();
    var pending: source_namespace.PendingTabRenamed = .{
        .request_id = request.request_id,
        .location = renamed.location,
        .label = undefined,
        .label_len = @intCast(label.len),
    };
    @memcpy(pending.label[0..pending.label_len], label);
    try controller.responses.push(.{ .tab_renamed = pending });
}

fn queueFailure(controller: *Controller, request_id: source_namespace.schema.RequestId, failure: Failure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
