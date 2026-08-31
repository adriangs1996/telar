//! Protocol controller for cell snapshot recovery requests. Accepted requests
//! emit no management response; the cell lane carries the eventual snapshot.

const std = @import("std");
const core = @import("telar-core");
const request_snapshot_commands = @import("../../application/commands/request_snapshot.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched snapshot controller for the cell delivery
/// path.
///
/// ```zig
/// const SnapshotController = Controller(*request_snapshot_commands.RequestCellSnapshotHandler);
/// var controller = SnapshotController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = SnapshotController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Requests a fresh server baseline for one pane. `known_frame_id` is
        /// advisory: recovery never trusts or replays the client's local
        /// baseline, so the pending recovery frame is always a full snapshot.
        ///
        /// ```zig
        /// try controller.requestSnapshot(request);
        /// ```
        pub inline fn requestSnapshot(controller: *Self, request: schema.RequestSnapshot) !void {
            _ = request.known_frame_id;
            const result = try controller.executor.execute(.{ .pane_id = request.pane_id });

            if (result == .pane_not_attached) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}

const StubExecutor = struct {
    result: request_snapshot_commands.RequestCellSnapshotResult = .requested,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?request_snapshot_commands.RequestCellSnapshot = null,

    fn execute(stub: *StubExecutor, command: request_snapshot_commands.RequestCellSnapshot) !request_snapshot_commands.RequestCellSnapshotResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

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
