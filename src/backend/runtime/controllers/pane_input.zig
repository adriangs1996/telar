//! Protocol controller for input sent to an attached pane.

const std = @import("std");
const core = @import("telar-core");
const pane_input_commands = @import("../commands/pane_input.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a controller around a statically dispatched command executor. The
/// concrete executor remains visible to the compiler so this protocol boundary
/// adds neither allocation nor indirect dispatch to the interactive path.
///
/// ```zig
/// const InputController = Controller(*pane_input_commands.PaneInputHandler);
/// var controller = InputController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = InputController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Forwards valid input and treats an absent or exited attachment as a
        /// stale client message. Scheduling failures remain infrastructure
        /// errors and propagate to the runtime's connection policy.
        ///
        /// ```zig
        /// try controller.paneInput(request);
        /// ```
        pub inline fn paneInput(controller: *Self, request: schema.PaneInput) !void {
            const result = try controller.executor.execute(.{
                .pane_id = request.pane_id,
                .bytes = request.bytes,
            });

            switch (result) {
                .handled => {},
                .pane_not_attached, .pane_exited => {
                    controller.metrics.stale_client_messages += 1;
                },
            }
        }
    };
}

const StubExecutor = struct {
    result: pane_input_commands.PaneInputResult = .handled,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?pane_input_commands.PaneInput = null,

    fn execute(stub: *StubExecutor, command: pane_input_commands.PaneInput) !pane_input_commands.PaneInputResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

const TestController = Controller(*StubExecutor);

test "Controller forwards the exact pane input without stale accounting" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.paneInput(.{ .pane_id = pane_id, .bytes = "help\r" });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqualStrings("help\r", stub.command.?.bytes);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts unavailable pane input as stale" {
    const pane_id = try schema.id.pane(7);

    for ([_]pane_input_commands.PaneInputResult{ .pane_not_attached, .pane_exited }) |result| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
        var stub: StubExecutor = .{ .result = result };
        var controller = TestController.init(&metrics, &stub);

        try controller.paneInput(.{ .pane_id = pane_id, .bytes = "x" });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
    }
}

test "Controller propagates infrastructure failures even when their names resemble stale results" {
    const pane_id = try schema.id.pane(7);

    for ([_]anyerror{ error.InputSchedulerUnavailable, error.PaneExited, error.PaneNotAttached }) |failure| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0 };
        var stub: StubExecutor = .{ .failure = failure };
        var controller = TestController.init(&metrics, &stub);

        try std.testing.expectError(failure, controller.paneInput(.{
            .pane_id = pane_id,
            .bytes = "x",
        }));

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
    }
}
