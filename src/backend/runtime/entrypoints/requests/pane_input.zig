//! Protocol controller for input sent to an attached pane.

const std = @import("std");
const core = @import("telar-core");
const pane_input_commands = @import("../../application/commands/pane_input.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericPaneInputController.zig").Type;

const StubExecutor = @import("PaneInputStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller forwards the exact pane input without stale accounting" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectEqual(.handled, try controller.paneInput(.{ .pane_id = pane_id, .bytes = "help\r" }));

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

        try std.testing.expectEqual(result, try controller.paneInput(.{ .pane_id = pane_id, .bytes = "x" }));

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
