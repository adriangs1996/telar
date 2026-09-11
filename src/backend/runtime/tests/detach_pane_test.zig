//! Vertical contract test for the runtime detach-pane flow.

const pane_module = @import("telar-core").pane;
const DetachPaneTestEffects = @import("DetachPaneTestEffects.zig");
const workspace_module = @import("telar-core").workspace;
const DetachPaneHandlerType = @import("../application/commands/DetachPaneHandler.zig");
const DetachPaneController = @import("../entrypoints/requests/DetachPaneController.zig");
const std = @import("std");

test "a detach request commits session state before releasing geometry" {
    const pane_id = try pane_module(7);
    var effects: DetachPaneTestEffects = .{ .detached = .{
        .pane_id = pane_id,
        .workspace = .{ .workspace = try workspace_module(3) },
        .last_attachment = true,
    } };
    var handler: DetachPaneHandlerType = .{
        .attachments = effects.attachments(),
        .geometry = effects.geometry(),
    };
    var controller = DetachPaneController.init(handler.executor(), effects.staleMessages());

    try controller.detachPane(.{ .pane_id = pane_id });

    try std.testing.expect(effects.attachment_committed);
    try std.testing.expect(effects.workspace_left);
    try std.testing.expect(effects.geometry_released);
    try std.testing.expectEqual(@as(usize, 0), effects.stale_count);
}
