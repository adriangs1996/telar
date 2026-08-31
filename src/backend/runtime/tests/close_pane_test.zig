//! Vertical contract tests for the runtime close-pane flow.

const std = @import("std");
const core = @import("telar-core");
const close_pane_commands = @import("../application/commands/close_pane.zig");
const close_pane_controller = @import("../entrypoints/requests/close_pane.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;

const PaneCapture = struct {
    attached_pane: schema.PaneId,
    requested: bool = false,

    fn port(capture: *PaneCapture) close_pane_commands.AttachedPaneCloser {
        return .{ .context = capture, .request_close = requestClose };
    }

    fn requestClose(context: *anyopaque, pane_id: schema.PaneId) ?bool {
        const capture: *PaneCapture = @ptrCast(@alignCast(context));

        if (pane_id != capture.attached_pane) {
            return null;
        }

        const newly_requested = !capture.requested;
        capture.requested = true;
        return newly_requested;
    }
};

test "repeated close requests cross controller and handler idempotently" {
    const pane_id = try schema.id.pane(7);
    var panes: PaneCapture = .{ .attached_pane = pane_id };
    var handler: close_pane_commands.ClosePaneHandler = .{ .panes = panes.port() };
    var responses: delivery_mod.ResponseQueue = .{};
    var controller = close_pane_controller.Controller.init(&responses, handler.executor());

    try controller.closePane(.{ .request_id = @enumFromInt(41), .pane_id = pane_id });
    try controller.closePane(.{ .request_id = @enumFromInt(42), .pane_id = pane_id });

    try std.testing.expect(panes.requested);
    try std.testing.expect(responses.peek() == null);
}
