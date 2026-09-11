//! Protocol controller for copying an attached pane selection to one client.

const std = @import("std");
const core = @import("telar-core");
const copy_selection_commands = @import("../../application/commands/copy_selection.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericCopySelectionController.zig").Type;

const StubExecutor = @import("CopySelectionStubExecutor.zig");

const StubClipboard = @import("StubClipboard.zig");

const TestController = Controller(*StubExecutor, *StubClipboard);

test "Controller maps exact coordinates and delivers copied bytes" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var executor: StubExecutor = .{ .bytes = "one\ntwo" };
    var clipboard: StubClipboard = .{};
    var controller = TestController.init(&metrics, &executor, &clipboard);

    controller.copySelection(.{
        .pane_id = pane_id,
        .start_x = 4,
        .start_y = 8,
        .end_x = 2,
        .end_y = 3,
        .linewise = true,
    });

    try std.testing.expectEqual(@as(usize, 1), executor.call_count);
    try std.testing.expectEqual(copy_selection_commands.scratch_bytes, executor.scratch_len);
    try std.testing.expectEqual(pane_id, executor.command.?.pane_id);
    try std.testing.expectEqual(@as(u16, 4), executor.command.?.start_x);
    try std.testing.expectEqual(@as(u32, 8), executor.command.?.start_y);
    try std.testing.expectEqual(@as(u16, 2), executor.command.?.end_x);
    try std.testing.expectEqual(@as(u32, 3), executor.command.?.end_y);
    try std.testing.expect(executor.command.?.linewise);
    try std.testing.expectEqual(@as(usize, 1), clipboard.call_count);
    try std.testing.expectEqual(pane_id, clipboard.pane_id);
    try std.testing.expectEqualStrings("one\ntwo", clipboard.slice());
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts only a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var executor: StubExecutor = .{ .outcome = .pane_not_attached };
    var clipboard: StubClipboard = .{};
    var controller = TestController.init(&metrics, &executor, &clipboard);

    controller.copySelection(.{
        .pane_id = try schema.id.pane(7),
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 0,
    });

    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(usize, 0), clipboard.call_count);
}

test "Controller preserves clipboard output for unavailable and oversized selections" {
    for ([_]StubExecutor{ .{ .outcome = .unavailable }, .{ .outcome = .too_large } }) |initial| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
        var executor = initial;
        var clipboard: StubClipboard = .{};
        _ = clipboard.setClipboard(try schema.id.pane(3), "pending");
        clipboard.call_count = 0;
        var controller = TestController.init(&metrics, &executor, &clipboard);

        controller.copySelection(.{
            .pane_id = try schema.id.pane(7),
            .start_x = 0,
            .start_y = 0,
            .end_x = 0,
            .end_y = 0,
        });

        try std.testing.expectEqual(@as(u64, 4), metrics.stale_client_messages);
        try std.testing.expectEqual(@as(usize, 0), clipboard.call_count);
        try std.testing.expectEqualStrings("pending", clipboard.slice());
    }
}
