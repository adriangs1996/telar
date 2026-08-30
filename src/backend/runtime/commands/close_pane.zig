//! Application command for requesting an attached pane to close.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const ClosePane = struct {
    pane_id: schema.PaneId,
};

pub const ClosePaneResult = struct {
    pane_id: schema.PaneId,
    newly_requested: bool,
};

pub const AttachedPaneCloser = struct {
    context: *anyopaque,
    request_close: *const fn (*anyopaque, schema.PaneId) ?bool,
};

pub const ClosePaneExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, ClosePane) anyerror!ClosePaneResult,

    /// Executes a close request through the bound application handler.
    ///
    /// ```zig
    /// const result = try executor.execute(.{ .pane_id = pane_id });
    /// ```
    pub fn execute(executor: ClosePaneExecutor, command: ClosePane) !ClosePaneResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const ClosePaneHandler = struct {
    panes: AttachedPaneCloser,

    /// Authorizes the pane through the requesting client's attachments and
    /// requests its idempotent PTY shutdown. Actual retirement happens later.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id });
    /// ```
    pub fn execute(handler: *ClosePaneHandler, command: ClosePane) !ClosePaneResult {
        const newly_requested = handler.panes.request_close(
            handler.panes.context,
            command.pane_id,
        ) orelse return error.PaneNotAttached;

        return .{
            .pane_id = command.pane_id,
            .newly_requested = newly_requested,
        };
    }

    /// Exposes this handler through the command interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *ClosePaneHandler) ClosePaneExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: ClosePane) !ClosePaneResult {
        const handler: *ClosePaneHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const PaneCapture = struct {
    result: ?bool,
    call_count: usize = 0,
    last_pane_id: schema.PaneId = .invalid,

    fn port(capture: *PaneCapture) AttachedPaneCloser {
        return .{ .context = capture, .request_close = requestClose };
    }

    fn requestClose(context: *anyopaque, pane_id: schema.PaneId) ?bool {
        const capture: *PaneCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.last_pane_id = pane_id;
        return capture.result;
    }
};

test "ClosePaneHandler returns the exact attached pane transition" {
    const pane_id = try schema.id.pane(7);

    for ([_]bool{ true, false }) |newly_requested| {
        var panes: PaneCapture = .{ .result = newly_requested };
        var handler: ClosePaneHandler = .{ .panes = panes.port() };

        const result = try handler.executor().execute(.{ .pane_id = pane_id });

        try std.testing.expectEqual(@as(usize, 1), panes.call_count);
        try std.testing.expectEqual(pane_id, panes.last_pane_id);
        try std.testing.expectEqual(pane_id, result.pane_id);
        try std.testing.expectEqual(newly_requested, result.newly_requested);
    }
}

test "ClosePaneHandler rejects panes outside the requesting attachments" {
    var panes: PaneCapture = .{ .result = null };
    var handler: ClosePaneHandler = .{ .panes = panes.port() };
    const pane_id = try schema.id.pane(7);

    try std.testing.expectError(error.PaneNotAttached, handler.execute(.{
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), panes.call_count);
    try std.testing.expectEqual(pane_id, panes.last_pane_id);
}
