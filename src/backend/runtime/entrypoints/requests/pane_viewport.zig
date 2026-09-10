//! Protocol controller for one client's pane viewport. Accepted requests have
//! no direct response; a changed viewport schedules a full cell snapshot.

const std = @import("std");
const core = @import("telar-core");
const pane_viewport_commands = @import("../../application/commands/pane_viewport.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched viewport controller for the cell delivery
/// path.
///
/// ```zig
/// const ViewportController = Controller(*pane_viewport_commands.SetPaneViewportHandler);
/// var controller = ViewportController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = ViewportController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps the wire viewport to its command and counts only a missing
        /// attachment as stale. Allocation failures remain infrastructure
        /// errors after the attachment restores its previous state.
        ///
        /// ```zig
        /// try controller.setPaneViewport(viewport);
        /// ```
        pub inline fn setPaneViewport(controller: *Self, viewport: schema.SetPaneViewport) !void {
            const result = try controller.executor.execute(.{
                .pane_id = viewport.pane_id,
                .offset = viewport.offset,
            });

            if (result == .pane_not_attached) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}

const StubExecutor = struct {
    result: pane_viewport_commands.SetPaneViewportResult = .changed,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?pane_viewport_commands.SetPaneViewport = null,

    fn execute(stub: *StubExecutor, command: pane_viewport_commands.SetPaneViewport) !pane_viewport_commands.SetPaneViewportResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

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
