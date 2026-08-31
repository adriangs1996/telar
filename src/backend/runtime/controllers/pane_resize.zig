//! Protocol controller for pane resize messages.

const std = @import("std");
const core = @import("telar-core");
const pane_resize_commands = @import("../commands/pane_resize.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched resize controller for the interactive path.
///
/// ```zig
/// const ResizeController = Controller(*pane_resize_commands.PaneResizeHandler);
/// var controller = ResizeController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = ResizeController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps attachment and geometry rejection to diagnostics while
        /// preserving scheduler and PTY failures as infrastructure errors.
        ///
        /// ```zig
        /// try controller.paneResize(request);
        /// ```
        pub inline fn paneResize(controller: *Self, request: schema.PaneResize) !void {
            const result = try controller.executor.execute(.{
                .pane_id = request.pane_id,
                .size = request.size,
            });

            switch (result) {
                .handled => {},
                .pane_not_attached => controller.metrics.stale_client_messages += 1,
                .geometry_rejected => controller.metrics.geometry_rejections += 1,
            }
        }
    };
}

const StubExecutor = struct {
    result: pane_resize_commands.PaneResizeResult = .handled,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?pane_resize_commands.PaneResize = null,

    fn execute(stub: *StubExecutor, command: pane_resize_commands.PaneResize) !pane_resize_commands.PaneResizeResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

const TestController = Controller(*StubExecutor);

test "Controller forwards the exact pane resize" {
    const pane_id = try schema.id.pane(7);
    const size: schema.TerminalSize = .{ .cols = 80, .rows = 24, .cell_width_px = 8, .cell_height_px = 16 };
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.paneResize(.{ .pane_id = pane_id, .size = size });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqualDeep(size, stub.command.?.size);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), metrics.geometry_rejections);
}

test "Controller accounts for resize policy rejections" {
    const pane_id = try schema.id.pane(7);

    for ([_]pane_resize_commands.PaneResizeResult{ .pane_not_attached, .geometry_rejected }) |result| {
        var metrics: RuntimeMetrics = .{
            .started_ns = 0,
            .stale_client_messages = 3,
            .geometry_rejections = 5,
        };
        var stub: StubExecutor = .{ .result = result };
        var controller = TestController.init(&metrics, &stub);

        try controller.paneResize(.{
            .pane_id = pane_id,
            .size = .{ .cols = 80, .rows = 24 },
        });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, if (result == .pane_not_attached) 4 else 3), metrics.stale_client_messages);
        try std.testing.expectEqual(@as(u64, if (result == .geometry_rejected) 6 else 5), metrics.geometry_rejections);
    }
}

test "Controller propagates resize infrastructure failures regardless of their names" {
    const pane_id = try schema.id.pane(7);

    for ([_]anyerror{ error.ResizeSchedulerUnavailable, error.PaneNotAttached, error.GeometryRejected }) |failure| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0 };
        var stub: StubExecutor = .{ .failure = failure };
        var controller = TestController.init(&metrics, &stub);

        try std.testing.expectError(failure, controller.paneResize(.{
            .pane_id = pane_id,
            .size = .{ .cols = 80, .rows = 24 },
        }));

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
        try std.testing.expectEqual(@as(u64, 0), metrics.geometry_rejections);
    }
}
