//! One replaceable absolute deadline backed by at most one select task.

const std = @import("std");
const client_clock = @import("clock.zig");

pub const Io = std.Io;
const monotonic = client_clock.monotonic;
pub const no_deadline = std.math.maxInt(u64);

const TimerEvent = union(enum) {
    deadline: anyerror!void,
    rescheduled: anyerror!void,
};

const TimerResult = enum {
    deadline,
    rescheduled,
};

pub const Update = enum {
    idle,
    retained,
    schedule,
};

pub const Scheduler = @import("Scheduler.zig");

/// Waits until the latest non-null deadline, following replacements in place.
///
/// ```zig
/// try deadline_timer.wait(io, &scheduler);
/// ```
pub fn wait(io: Io, scheduler: *Scheduler) anyerror!void {
    while (true) {
        const deadline_ns = scheduler.deadline_ns.load(.acquire);
        if (deadline_ns == no_deadline) {
            try scheduler.wake.wait(io);
            scheduler.wake.reset();
            continue;
        }
        if (monotonic(io) >= deadline_ns) {
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

test "deadline completion releases the worker on every result" {
    var scheduler: Scheduler = .{ .pending = true };

    try scheduler.complete({});
    try std.testing.expect(!scheduler.pending);

    scheduler.pending = true;
    try std.testing.expectError(error.TimerFailed, scheduler.complete(error.TimerFailed));
    try std.testing.expect(!scheduler.pending);
}

test "deadline replacement retains one worker and wakes obsolete waits" {
    const io = std.testing.io;
    var scheduler: Scheduler = .{};
    const first = monotonic(io) + std.time.ns_per_s;
    const second = first + std.time.ns_per_s;

    try std.testing.expectEqual(Update.schedule, scheduler.update(io, first));
    try std.testing.expectEqual(Update.retained, scheduler.update(io, second));
    try std.testing.expectEqual(second, scheduler.deadline_ns.load(.acquire));
    try std.testing.expectEqual(
        TimerResult.rescheduled,
        try waitForTimerEvent(io, &scheduler, first),
    );
    scheduler.wake.reset();

    scheduler.schedulingFailed();
    try std.testing.expect(!scheduler.pending);
}

test "an unchanged deadline retains its worker without another wake" {
    const io = std.testing.io;
    const deadline_ns = monotonic(io) + std.time.ns_per_s;
    var scheduler: Scheduler = .{
        .deadline_ns = .init(deadline_ns),
        .pending = true,
    };

    try std.testing.expectEqual(Update.retained, scheduler.update(io, deadline_ns));
    try std.testing.expect(!scheduler.wake.isSet());
}

test "removing a deadline retains and parks its existing worker" {
    const io = std.testing.io;
    var scheduler: Scheduler = .{ .pending = true };

    try std.testing.expectEqual(Update.retained, scheduler.update(io, null));
    try std.testing.expectEqual(no_deadline, scheduler.deadline_ns.load(.acquire));
    try std.testing.expect(scheduler.pending);
}

test "a parked worker follows the next deadline without a second task" {
    const Completion = union(enum) {
        done: anyerror!void,
    };

    const io = std.testing.io;
    var scheduler: Scheduler = .{};
    var storage: [1]Completion = undefined;
    var select = Io.Select(Completion).init(io, &storage);
    defer select.cancelDiscard();

    try std.testing.expectEqual(
        Update.schedule,
        scheduler.update(io, monotonic(io) + std.time.ns_per_s),
    );
    try select.concurrent(.done, wait, .{ io, &scheduler });
    try std.testing.expectEqual(Update.retained, scheduler.update(io, null));
    try std.testing.expectEqual(Update.retained, scheduler.update(io, monotonic(io)));

    switch (try select.await()) {
        .done => |result| try scheduler.complete(result),
    }
    try std.testing.expect(!scheduler.pending);
}
