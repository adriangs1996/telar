//! Protocol controller for cell snapshot recovery requests. Accepted requests
//! emit no management response; the cell lane carries the eventual snapshot.

const std = @import("std");
const core = @import("telar-core");
const request_snapshot_commands = @import("../../application/commands/request_snapshot.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericRequestSnapshotController.zig").Type;

const StubExecutor = @import("RequestSnapshotStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller maps advisory frame state to an unconditional snapshot command" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.requestSnapshot(.{
        .pane_id = pane_id,
        .known_frame_id = std.math.maxInt(u64),
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts a snapshot request for a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .pane_not_attached };
    var controller = TestController.init(&metrics, &stub);

    try controller.requestSnapshot(.{
        .pane_id = try schema.id.pane(7),
        .known_frame_id = 3,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
}

test "Controller propagates snapshot infrastructure failures without stale accounting" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .failure = error.SnapshotUnavailable };
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectError(error.SnapshotUnavailable, controller.requestSnapshot(.{
        .pane_id = try schema.id.pane(7),
        .known_frame_id = 3,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}
