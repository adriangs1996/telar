//! Protocol controller for bounded pane text reads. The pane is resolved when
//! the response is encoded, so a read never borrows pane storage.

const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const ReadPaneController = @import("ReadPaneController.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");
const PaneTextSourceType = @import("telar-core").PaneTextSource;

test "Controller queues the exact read for late binding" {
    var responses: ResponseQueue = .{};
    var controller = ReadPaneController.init(&responses);

    try controller.readPane(.{
        .request_id = @enumFromInt(9),
        .pane_id = try pane_module(7),
        .pane_generation = 2,
        .rows = 25,
        .source = .recent,
    });

    const pending = responses.items[0].pane_text;
    try std.testing.expectEqual(@as(u64, 9), @intFromEnum(pending.request_id));
    try std.testing.expectEqual(@as(u64, 2), pending.pane.generation);
    try std.testing.expectEqual(@as(u16, 25), pending.rows);
    try std.testing.expectEqual(PaneTextSourceType.recent, pending.source);
}
