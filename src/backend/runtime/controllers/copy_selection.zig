//! Protocol controller for copying an attached pane selection to one client.

const std = @import("std");
const core = @import("telar-core");
const copy_selection_commands = @import("../commands/copy_selection.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched selection controller. `Clipboard` owns only
/// confirmed output; extraction uses request-scoped scratch storage.
///
/// ```zig
/// const SelectionController = Controller(*copy_selection_commands.CopySelectionHandler, *Delivery);
/// var controller = SelectionController.init(&metrics, &handler, &delivery);
/// ```
pub fn Controller(comptime Executor: type, comptime Clipboard: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,
        clipboard: Clipboard,
        scratch: [copy_selection_commands.scratch_bytes]u8 = undefined,

        /// Creates one request-scoped controller without modifying pending
        /// clipboard delivery.
        ///
        /// ```zig
        /// var controller = SelectionController.init(&metrics, &handler, &delivery);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor, clipboard: Clipboard) Self {
            return .{
                .metrics = metrics,
                .executor = executor,
                .clipboard = clipboard,
            };
        }

        /// Maps absolute scrollback coordinates, extracts bounded text, and
        /// replaces pending clipboard output only after successful extraction.
        /// A request for a pane outside this client's attachments is stale;
        /// unavailable and oversized selections are ignored.
        ///
        /// ```zig
        /// controller.copySelection(request);
        /// ```
        pub fn copySelection(controller: *Self, request: schema.CopySelection) void {
            const result = controller.executor.execute(.{
                .pane_id = request.pane_id,
                .start_x = request.start_x,
                .start_y = request.start_y,
                .end_x = request.end_x,
                .end_y = request.end_y,
                .linewise = request.linewise,
            }, &controller.scratch);

            switch (result) {
                .copied => |bytes| {
                    const accepted = controller.clipboard.setClipboard(request.pane_id, bytes);
                    std.debug.assert(accepted);
                },
                .pane_not_attached => controller.metrics.stale_client_messages += 1,
                .unavailable, .too_large => {},
            }
        }
    };
}

const StubExecutor = struct {
    outcome: enum { copied, pane_not_attached, unavailable, too_large } = .copied,
    bytes: []const u8 = "selected",
    call_count: usize = 0,
    scratch_len: usize = 0,
    command: ?copy_selection_commands.CopySelection = null,

    fn execute(stub: *StubExecutor, command: copy_selection_commands.CopySelection, scratch: []u8) copy_selection_commands.CopySelectionResult {
        stub.call_count += 1;
        stub.scratch_len = scratch.len;
        stub.command = command;

        return switch (stub.outcome) {
            .copied => copied: {
                std.debug.assert(stub.bytes.len <= scratch.len);
                @memcpy(scratch[0..stub.bytes.len], stub.bytes);
                break :copied .{ .copied = scratch[0..stub.bytes.len] };
            },
            .pane_not_attached => .pane_not_attached,
            .unavailable => .unavailable,
            .too_large => .too_large,
        };
    }
};

const StubClipboard = struct {
    accepted: bool = true,
    call_count: usize = 0,
    pane_id: schema.PaneId = .invalid,
    bytes: [32]u8 = undefined,
    len: usize = 0,

    fn setClipboard(clipboard: *StubClipboard, pane_id: schema.PaneId, bytes: []const u8) bool {
        clipboard.call_count += 1;
        if (!clipboard.accepted or bytes.len > clipboard.bytes.len) {
            return false;
        }

        clipboard.pane_id = pane_id;
        @memcpy(clipboard.bytes[0..bytes.len], bytes);
        clipboard.len = bytes.len;
        return true;
    }

    fn slice(clipboard: *const StubClipboard) []const u8 {
        return clipboard.bytes[0..clipboard.len];
    }
};

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
