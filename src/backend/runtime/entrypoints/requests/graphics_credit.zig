//! Protocol controller for graphics credit returns. Accepted messages emit no
//! management response; the runtime's normal post-dispatch pump resumes media.

const std = @import("std");
const core = @import("telar-core");
const graphics_credit_commands = @import("../../application/commands/graphics_credit.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericGraphicsCreditController.zig").Type;

const StubExecutor = @import("GraphicsCreditStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller maps the exact graphics credit return" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.graphicsCredit(.{ .pane_id = pane_id, .bytes = 4096 });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 4096), stub.command.?.bytes);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts every rejected graphics credit return as stale" {
    for ([_]graphics_credit_commands.ReturnGraphicsCreditResult{ .pane_not_attached, .invalid_amount }) |result| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
        var stub: StubExecutor = .{ .result = result };
        var controller = TestController.init(&metrics, &stub);

        try controller.graphicsCredit(.{
            .pane_id = try schema.id.pane(7),
            .bytes = 1,
        });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
    }
}

test "Controller propagates credit infrastructure failures without stale accounting" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .failure = error.GraphicsCreditUnavailable };
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectError(error.GraphicsCreditUnavailable, controller.graphicsCredit(.{
        .pane_id = try schema.id.pane(7),
        .bytes = 1,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}
