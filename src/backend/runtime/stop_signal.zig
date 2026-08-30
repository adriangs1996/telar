//! Optional infrastructure stop signal for one runtime instance.

const std = @import("std");

const Io = std.Io;

pub const Completion = enum {
    stop,
};

pub const Scheduler = struct {
    context: *anyopaque,
    schedule_fn: *const fn (*anyopaque, *Io.Queue(u8)) anyerror!void,

    fn schedule(scheduler: Scheduler, queue: *Io.Queue(u8)) !void {
        return scheduler.schedule_fn(scheduler.context, queue);
    }
};

pub const Coordinator = struct {
    queue: ?*Io.Queue(u8),

    /// Borrows an optional external queue for the coordinator's lifetime.
    ///
    /// ```zig
    /// const stop_signal = Coordinator.init(&queue);
    /// ```
    pub fn init(queue: ?*Io.Queue(u8)) Coordinator {
        return .{ .queue = queue };
    }

    /// Schedules one wait when an external stop queue is configured.
    /// Disabled coordinators treat arming as a successful no-op.
    ///
    /// ```zig
    /// try stop_signal.arm(scheduler);
    /// ```
    pub fn arm(coordinator: Coordinator, scheduler: Scheduler) !void {
        const queue = coordinator.queue orelse return;
        try scheduler.schedule(queue);
    }

    /// Converts a successful signal completion into the terminal event-loop
    /// action and preserves the exact source error on failure.
    ///
    /// ```zig
    /// if (try stop_signal.complete(result) == .stop) {
    ///     return;
    /// }
    /// ```
    pub fn complete(coordinator: Coordinator, result: anyerror!void) !Completion {
        std.debug.assert(coordinator.queue != null);
        try result;
        return .stop;
    }
};

/// Waits until the borrowed queue produces one stop token.
///
/// ```zig
/// try wait(io, &queue);
/// ```
pub fn wait(io: Io, queue: *Io.Queue(u8)) !void {
    _ = try queue.getOne(io);
}

const ScheduleCapture = struct {
    calls: usize = 0,
    queue: ?*Io.Queue(u8) = null,
    failure: ?anyerror = null,

    fn scheduler(capture: *ScheduleCapture) Scheduler {
        return .{ .context = capture, .schedule_fn = schedule };
    }

    fn schedule(context: *anyopaque, queue: *Io.Queue(u8)) !void {
        const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.queue = queue;

        if (capture.failure) |err| {
            return err;
        }
    }
};

test "a disabled stop signal does not schedule a wait" {
    const coordinator = Coordinator.init(null);
    var capture: ScheduleCapture = .{};

    try coordinator.arm(capture.scheduler());

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expect(capture.queue == null);
}

test "an active stop signal schedules its exact borrowed queue" {
    var storage: [1]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&storage);
    const coordinator = Coordinator.init(&queue);
    var capture: ScheduleCapture = .{};

    try coordinator.arm(capture.scheduler());

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.queue == &queue);
}

test "a scheduling failure is propagated without losing the queue" {
    var storage: [1]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&storage);
    const coordinator = Coordinator.init(&queue);
    var capture: ScheduleCapture = .{ .failure = error.SchedulerUnavailable };

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.arm(capture.scheduler()));
    try std.testing.expect(coordinator.queue == &queue);
}

test "a successful stop completion terminates the event loop" {
    var storage: [1]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&storage);
    const coordinator = Coordinator.init(&queue);

    try std.testing.expectEqual(Completion.stop, try coordinator.complete({}));
}

test "a failed stop completion preserves the source error" {
    var storage: [1]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&storage);
    const coordinator = Coordinator.init(&queue);

    try std.testing.expectError(error.StopSourceClosed, coordinator.complete(error.StopSourceClosed));
}

test "wait consumes one queue token" {
    const io = std.testing.io;
    var storage: [1]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&storage);
    var pending = try io.concurrent(wait, .{ io, &queue });

    try queue.putOne(io, 7);
    try pending.await(io);
}
