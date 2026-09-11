//! Protocol controller for one client's pane viewport. Accepted requests have
//! no direct response; a changed viewport schedules a full cell snapshot.

const std = @import("std");
const core = @import("telar-core");
const pane_viewport_commands = @import("../../application/commands/pane_viewport.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericPaneViewportController.zig").Type;

const StubExecutor = @import("PaneViewportStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller maps the exact pane viewport" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.setPaneViewport(.{ .pane_id = pane_id, .offset = 41 });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u32, 41), stub.command.?.offset);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller does not count an unchanged viewport as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .unchanged };
    var controller = TestController.init(&metrics, &stub);

    try controller.setPaneViewport(.{
        .pane_id = try schema.id.pane(7),
        .offset = 0,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 4), metrics.stale_client_messages);
}

test "Controller counts a viewport for a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .pane_not_attached };
    var controller = TestController.init(&metrics, &stub);

    try controller.setPaneViewport(.{
        .pane_id = try schema.id.pane(7),
        .offset = 0,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
}

test "Controller propagates viewport infrastructure failures without stale accounting" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .failure = error.OutOfMemory };
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectError(error.OutOfMemory, controller.setPaneViewport(.{
        .pane_id = try schema.id.pane(7),
        .offset = 0,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}
