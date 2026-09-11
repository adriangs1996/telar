//! Vertical contract test for the runtime detach-pane flow.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment/root.zig");
const detach_pane_commands = @import("../application/commands/detach_pane.zig");
const detach_pane_controller = @import("../entrypoints/requests/detach_pane.zig");

pub const schema = core.schema;

const Effects = @import("DetachPaneTestEffects.zig");

test "a detach request commits session state before releasing geometry" {
    const pane_id = try schema.id.pane(7);
    var effects: Effects = .{ .detached = .{
        .pane_id = pane_id,
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .last_attachment = true,
    } };
    var handler: detach_pane_commands.DetachPaneHandler = .{
        .attachments = effects.attachments(),
        .geometry = effects.geometry(),
    };
    var controller = detach_pane_controller.Controller.init(handler.executor(), effects.staleMessages());

    try controller.detachPane(.{ .pane_id = pane_id });

    try std.testing.expect(effects.attachment_committed);
    try std.testing.expect(effects.workspace_left);
    try std.testing.expect(effects.geometry_released);
    try std.testing.expectEqual(@as(usize, 0), effects.stale_count);
}
