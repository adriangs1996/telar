//! Protocol controller for graphics snapshot recovery. Accepted requests emit
//! no management response; the media lane carries the replacement snapshot.

const std = @import("std");
const core = @import("telar-core");
const request_graphics_snapshot_commands = @import("../commands/request_graphics_snapshot.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched controller for graphics recovery requests.
///
/// ```zig
/// const GraphicsSnapshotController = Controller(*request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler);
/// var controller = GraphicsSnapshotController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = GraphicsSnapshotController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps the wire request to an unconditional graphics recovery command
        /// and counts only a pane outside this client's attachments as stale.
        ///
        /// ```zig
        /// try controller.requestGraphicsSnapshot(request);
        /// ```
        pub inline fn requestGraphicsSnapshot(controller: *Self, request: schema.RequestGraphicsSnapshot) !void {
            const result = try controller.executor.execute(.{ .pane_id = request.pane_id });

            if (result == .pane_not_attached) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}

const StubExecutor = struct {
    result: request_graphics_snapshot_commands.RequestGraphicsSnapshotResult = .requested,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?request_graphics_snapshot_commands.RequestGraphicsSnapshot = null,

    fn execute(stub: *StubExecutor, command: request_graphics_snapshot_commands.RequestGraphicsSnapshot) !request_graphics_snapshot_commands.RequestGraphicsSnapshotResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

const TestController = Controller(*StubExecutor);

test "Controller maps the exact graphics snapshot pane" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.requestGraphicsSnapshot(.{ .pane_id = pane_id });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts a graphics snapshot for a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .pane_not_attached };
    var controller = TestController.init(&metrics, &stub);

    try controller.requestGraphicsSnapshot(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
}

test "Controller propagates graphics recovery failures without stale accounting" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .failure = error.GraphicsRecoveryUnavailable };
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectError(
        error.GraphicsRecoveryUnavailable,
        controller.requestGraphicsSnapshot(.{ .pane_id = try schema.id.pane(7) }),
    );

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}
