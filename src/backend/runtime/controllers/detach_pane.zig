//! Request-scoped controller for the detach-pane protocol message.

const std = @import("std");
const core = @import("telar-core");
const detach_pane_commands = @import("../commands/detach_pane.zig");

const schema = core.schema;

pub const StaleMessages = struct {
    context: *anyopaque,
    record: *const fn (*anyopaque) void,
};

pub const Controller = struct {
    detach_pane: detach_pane_commands.DetachPaneExecutor,
    stale_messages: StaleMessages,

    /// Creates a request-scoped detach controller.
    ///
    /// ```zig
    /// var controller = Controller.init(handler.executor(), stale_messages);
    /// ```
    pub fn init(detach_pane: detach_pane_commands.DetachPaneExecutor, stale_messages: StaleMessages) Controller {
        return .{ .detach_pane = detach_pane, .stale_messages = stale_messages };
    }

    /// Maps the wire request into the detach command and records a stale
    /// client message when the requested pane is not attached.
    ///
    /// ```zig
    /// try controller.detachPane(request);
    /// ```
    pub fn detachPane(controller: *Controller, request: schema.DetachPane) !void {
        const result = try controller.detach_pane.execute(.{ .pane_id = request.pane_id });

        if (result == .not_attached) {
            controller.stale_messages.record(controller.stale_messages.context);
        }
    }
};

const Capture = struct {
    result: detach_pane_commands.DetachPaneResult,
    command_count: usize = 0,
    stale_count: usize = 0,
    pane_id: schema.PaneId = .invalid,
    failure: ?anyerror = null,

    fn executor(capture: *Capture) detach_pane_commands.DetachPaneExecutor {
        return .{ .context = capture, .execute_fn = execute };
    }

    fn staleMessages(capture: *Capture) StaleMessages {
        return .{ .context = capture, .record = recordStale };
    }

    fn execute(context: *anyopaque, command: detach_pane_commands.DetachPane) !detach_pane_commands.DetachPaneResult {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.command_count += 1;
        capture.pane_id = command.pane_id;

        if (capture.failure) |failure| {
            return failure;
        }

        return capture.result;
    }

    fn recordStale(context: *anyopaque) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.stale_count += 1;
    }
};

test "Controller maps detach-pane requests without a success response" {
    const pane_id = try schema.id.pane(7);
    var capture: Capture = .{ .result = .detached };
    var controller = Controller.init(capture.executor(), capture.staleMessages());

    try controller.detachPane(.{ .pane_id = pane_id });

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(pane_id, capture.pane_id);
    try std.testing.expectEqual(@as(usize, 0), capture.stale_count);
}

test "Controller records one stale message for a missing attachment" {
    var capture: Capture = .{ .result = .not_attached };
    var controller = Controller.init(capture.executor(), capture.staleMessages());

    try controller.detachPane(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(@as(usize, 1), capture.stale_count);
}

test "Controller propagates unexpected detach failures without recording stale input" {
    var capture: Capture = .{
        .result = .detached,
        .failure = error.AttachmentStateConflict,
    };
    var controller = Controller.init(capture.executor(), capture.staleMessages());

    try std.testing.expectError(error.AttachmentStateConflict, controller.detachPane(.{
        .pane_id = try schema.id.pane(7),
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(@as(usize, 0), capture.stale_count);
}
