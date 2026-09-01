//! Application command for initiating runtime shutdown exactly once.

const std = @import("std");
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;

pub const RuntimeStop = struct {
    requester: shutdown_mod.ClientKey,
};

pub const RuntimeStopResult = enum {
    requested,
    already_requested,
};

pub const Notifications = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, shutdown_mod.StopRequested) void,

    /// Publishes the committed shutdown event to runtime delivery.
    ///
    /// ```zig
    /// notifications.publish(event);
    /// ```
    pub fn publish(notifications: Notifications, event: shutdown_mod.StopRequested) void {
        notifications.publish_fn(notifications.context, event);
    }
};

pub const RuntimeStopExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, RuntimeStop) RuntimeStopResult,

    /// Executes one runtime-stop command through its bound handler.
    ///
    /// ```zig
    /// const result = executor.execute(.{ .requester = client });
    /// ```
    pub fn execute(executor: RuntimeStopExecutor, command: RuntimeStop) RuntimeStopResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const RuntimeStopHandler = struct {
    shutdown: *shutdown_mod.State,
    notifications: Notifications,

    /// Commits first-writer shutdown authority before publishing exactly one
    /// typed notification. Repeated commands have no effect.
    ///
    /// ```zig
    /// const result = handler.execute(.{ .requester = client });
    /// ```
    pub fn execute(handler: *RuntimeStopHandler, command: RuntimeStop) RuntimeStopResult {
        const event = handler.shutdown.request(command.requester) orelse {
            return .already_requested;
        };

        handler.notifications.publish(event);
        return .requested;
    }

    /// Exposes this handler through the command interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *RuntimeStopHandler) RuntimeStopExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: RuntimeStop) RuntimeStopResult {
        const handler: *RuntimeStopHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const PublicationCapture = struct {
    shutdown: *const shutdown_mod.State,
    calls: usize = 0,
    event: ?shutdown_mod.StopRequested = null,
    observed_committed_state: bool = false,

    fn notifications(capture: *PublicationCapture) Notifications {
        return .{ .context = capture, .publish_fn = publish };
    }

    fn publish(context: *anyopaque, event: shutdown_mod.StopRequested) void {
        const capture: *PublicationCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.event = event;
        capture.observed_committed_state = capture.shutdown.isRequested();
    }
};

test "RuntimeStopHandler commits authority before publishing one event" {
    var shutdown: shutdown_mod.State = .{};
    var capture: PublicationCapture = .{ .shutdown = &shutdown };
    var handler: RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = capture.notifications(),
    };
    const requester: shutdown_mod.ClientKey = .{ .id = 12, .generation = 5 };

    const result = handler.executor().execute(.{ .requester = requester });

    try std.testing.expectEqual(RuntimeStopResult.requested, result);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(requester, capture.event.?.initiator);
    try std.testing.expectEqualDeep(requester, shutdown.initiator.?);
}

test "RuntimeStopHandler ignores every request after the first" {
    var shutdown: shutdown_mod.State = .{};
    var capture: PublicationCapture = .{ .shutdown = &shutdown };
    var handler: RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = capture.notifications(),
    };
    const first: shutdown_mod.ClientKey = .{ .id = 1, .generation = 2 };
    const second: shutdown_mod.ClientKey = .{ .id = 3, .generation = 4 };

    try std.testing.expectEqual(RuntimeStopResult.requested, handler.execute(.{ .requester = first }));
    try std.testing.expectEqual(RuntimeStopResult.already_requested, handler.execute(.{ .requester = first }));
    try std.testing.expectEqual(RuntimeStopResult.already_requested, handler.execute(.{ .requester = second }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(first, shutdown.initiator.?);
}
