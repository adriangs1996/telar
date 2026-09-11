const DetachPaneExecutorType = @import("../../application/commands/DetachPaneExecutor.zig");
const StaleMessages = @import("StaleMessages.zig");
const DetachPaneType = @import("telar-core").DetachPane;
const Controller = @This();

detach_pane: DetachPaneExecutorType,
stale_messages: StaleMessages,

/// Creates a request-scoped detach controller.
///
/// ```zig
/// var controller = Controller.init(handler.executor(), stale_messages);
/// ```
pub fn init(detach_pane: DetachPaneExecutorType, stale_messages: StaleMessages) Controller {
    return .{ .detach_pane = detach_pane, .stale_messages = stale_messages };
}

/// Maps the wire request into the detach command and records a stale
/// client message when the requested pane is not attached.
///
/// ```zig
/// try controller.detachPane(request);
/// ```
pub fn detachPane(controller: *Controller, request: DetachPaneType) !void {
    const result = try controller.detach_pane.execute(.{ .pane_id = request.pane_id });

    if (result == .not_attached) {
        controller.stale_messages.record(controller.stale_messages.context);
    }
}
