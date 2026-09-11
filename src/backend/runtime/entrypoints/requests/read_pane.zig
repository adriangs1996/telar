//! Protocol controller for bounded pane text reads. The pane is resolved when
//! the response is encoded, so a read never borrows pane storage.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("ReadPaneController.zig");

test "Controller queues the exact read for late binding" {
    var responses: ResponseQueue = .{};
    var controller = Controller.init(&responses);

    try controller.readPane(.{
        .request_id = @enumFromInt(9),
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .rows = 25,
        .source = .recent,
    });

    const pending = responses.items[0].pane_text;
    try std.testing.expectEqual(@as(u64, 9), @intFromEnum(pending.request_id));
    try std.testing.expectEqual(@as(u64, 2), pending.pane.generation);
    try std.testing.expectEqual(@as(u16, 25), pending.rows);
    try std.testing.expectEqual(schema.PaneTextSource.recent, pending.source);
}
