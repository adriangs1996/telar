//! Owns the replaceable timer used by the client notification lifecycle.

const std = @import("std");

const client_mod = @import("client.zig");
const Client = client_mod;
const Io = std.Io;

const no_deadline = std.math.maxInt(u64);

const TimerEvent = union(enum) {
    deadline: anyerror!void,
    rescheduled: anyerror!void,
};

const TimerResult = enum {
    deadline,
    rescheduled,
};

pub const Scheduler = struct {
    deadline_ns: std.atomic.Value(u64) = .init(no_deadline),
    wake: Io.Event = .unset,
    pending: bool = false,
};

/// Replaces the pending deadline from current model state and starts at most
/// one client select task.
///
/// ```zig
/// try reschedule(client);
/// ```
pub fn reschedule(client: *Client) !void {
    const scheduler = &client.notification_scheduler;
    const now_ns = client_mod.monotonic(client.io);
    const deadline_ns = client.model.nextNotificationDeadline(
        now_ns,
        client.presenter.pacer.interval,
    ) orelse return;
    scheduler.deadline_ns.store(deadline_ns, .release);
    if (scheduler.pending) {
        scheduler.wake.set(client.io);
        return;
    }

    // No waiter exists after the previous task completes. Reset any wake that
    // raced with its completion before publishing the replacement task.
    scheduler.wake.reset();
    scheduler.pending = true;
    client.select.concurrent(.notification_tick, waitForTick, .{
        client.io,
        scheduler,
    }) catch |err| {
        scheduler.pending = false;
        return err;
    };
}

/// Releases the completed select task before propagating its result.
///
/// ```zig
/// try complete(client, result);
/// ```
pub fn complete(client: *Client, result: anyerror!void) !void {
    try finish(&client.notification_scheduler, result);
}

fn finish(scheduler: *Scheduler, result: anyerror!void) !void {
    scheduler.pending = false;
    try result;
}

fn waitForTick(io: Io, scheduler: *Scheduler) anyerror!void {
    while (true) {
        const deadline_ns = scheduler.deadline_ns.load(.acquire);
        if (client_mod.monotonic(io) >= deadline_ns) {
            return;
        }

        switch (try waitForTimerEvent(io, scheduler, deadline_ns)) {
            .deadline => return,
            .rescheduled => scheduler.wake.reset(),
        }
    }
}

fn waitForTimerEvent(io: Io, scheduler: *Scheduler, deadline_ns: u64) anyerror!TimerResult {
    var storage: [2]TimerEvent = undefined;
    var select = Io.Select(TimerEvent).init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.deadline, waitUntil, .{ io, deadline_ns });
    try select.concurrent(.rescheduled, waitForReschedule, .{ io, &scheduler.wake });

    return switch (try select.await()) {
        .deadline => |result| block: {
            try result;
            break :block .deadline;
        },
        .rescheduled => |result| block: {
            try result;
            break :block .rescheduled;
        },
    };
}

fn waitUntil(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn waitForReschedule(io: Io, event: *Io.Event) anyerror!void {
    try event.wait(io);
}

test "notification timer completion releases pending state on every result" {
    var scheduler: Scheduler = .{ .pending = true };

    try finish(&scheduler, {});
    try std.testing.expect(!scheduler.pending);

    scheduler.pending = true;
    try std.testing.expectError(error.TimerFailed, finish(&scheduler, error.TimerFailed));
    try std.testing.expect(!scheduler.pending);
}

test "notification timer wake overtakes an obsolete deadline" {
    const io = std.testing.io;
    var scheduler: Scheduler = .{};
    const deadline_ns = client_mod.monotonic(io) + std.time.ns_per_s;
    scheduler.wake.set(io);

    try std.testing.expectEqual(
        TimerResult.rescheduled,
        try waitForTimerEvent(io, &scheduler, deadline_ns),
    );
    scheduler.wake.reset();
}
