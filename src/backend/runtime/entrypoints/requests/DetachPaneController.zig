const Controller = @This();
const detach_pane_commands = @import("../../application/commands/detach_pane.zig");
const StaleMessages = @import("StaleMessages.zig");
const source_namespace = @import("detach_pane.zig");
detach_pane: detach_pane_commands.DetachPaneExecutor,
stale_messages: StaleMessages,

/// Creates a request-scoped detach controller.
///
/// ```zig
/// var controller = Controller.init(handler.executor(), stale_messages);
/// ```
pub fn init(detach_pane: detach_pane_commands.DetachPaneExecutor, stale_messages: StaleMessages) Controller {
    return .{ .detach_pane = detach_pane, .stale_messages = stale_messages };
}

/// Maps the wire request into the detach command and records a stale
/// client message when the requested pane is not attached.
///
/// ```zig
/// try controller.detachPane(request);
/// ```
pub fn detachPane(controller: *Controller, request: source_namespace.schema.DetachPane) !void {
    const result = try controller.detach_pane.execute(.{ .pane_id = request.pane_id });

    if (result == .not_attached) {
        controller.stale_messages.record(controller.stale_messages.context);
    }
}
