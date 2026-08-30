//! Protocol controller for graphics credit returns. Accepted messages emit no
//! management response; the runtime's normal post-dispatch pump resumes media.

const std = @import("std");
const core = @import("telar-core");
const graphics_credit_commands = @import("../commands/graphics_credit.zig");
const telemetry_mod = @import("../telemetry.zig");

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched controller for graphics flow control.
///
/// ```zig
/// const GraphicsCreditController = Controller(*graphics_credit_commands.ReturnGraphicsCreditHandler);
/// var controller = GraphicsCreditController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = GraphicsCreditController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Returns the exact wire amount and counts missing attachments or
        /// amounts outside the attachment's outstanding credit as stale.
        ///
        /// ```zig
        /// try controller.graphicsCredit(credit);
        /// ```
        pub inline fn graphicsCredit(controller: *Self, credit: schema.GraphicsCredit) !void {
            const result = try controller.executor.execute(.{
                .pane_id = credit.pane_id,
                .bytes = credit.bytes,
            });

            if (result != .returned) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}

const StubExecutor = struct {
    result: graphics_credit_commands.ReturnGraphicsCreditResult = .returned,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?graphics_credit_commands.ReturnGraphicsCredit = null,

    fn execute(stub: *StubExecutor, command: graphics_credit_commands.ReturnGraphicsCredit) !graphics_credit_commands.ReturnGraphicsCreditResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

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
