//! Protocol controller for bounded pane text reads. The pane is resolved when
//! the response is encoded, so a read never borrows pane storage.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,

    /// Creates one controller bound to the requesting client's responses.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses);
    /// ```
    pub fn init(responses: *ResponseQueue) Controller {
        return .{ .responses = responses };
    }

    /// Queues one late-bound text read for the exact pane generation.
    ///
    /// ```zig
    /// try controller.readPane(request);
    /// ```
    pub fn readPane(controller: *Controller, request: schema.ReadPane) !void {
        try controller.responses.push(.{ .pane_text = .{
            .request_id = request.request_id,
            .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
            .rows = request.rows,
            .source = request.source,
        } });
    }
};

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
