//! One replaceable absolute deadline backed by at most one host timer worker.

const std = @import("std");
const Scheduler = @import("DeadlineScheduler.zig");
const clock = @import("clock.zig");

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

/// Waits until the latest non-null deadline, following replacements in place.
///
/// ```zig
/// try deadline_timer.wait(io, &scheduler);
/// ```
pub fn wait(io: std.Io, scheduler: *Scheduler) anyerror!void {
    while (true) {
        const deadline_ns = scheduler.deadline_ns.load(.acquire);
        if (deadline_ns == no_deadline) {
            try scheduler.wake.wait(io);
            scheduler.wake.reset();
            continue;
        }
        if (clock.monotonic(io) >= deadline_ns) {
            return;
        }

        switch (try waitForTimerEvent(io, scheduler, deadline_ns)) {
            .deadline => return,
            .rescheduled => scheduler.wake.reset(),
        }
    }
}

fn waitForTimerEvent(io: std.Io, scheduler: *Scheduler, deadline_ns: u64) anyerror!TimerResult {
    var storage: [2]TimerEvent = undefined;
    var select = std.Io.Select(TimerEvent).init(io, &storage);
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

fn waitUntil(io: std.Io, deadline_ns: u64) anyerror!void {
    const deadline = std.Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);

    try deadline.wait(io);
}

fn waitForReschedule(io: std.Io, event: *std.Io.Event) anyerror!void {
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
    const first = clock.monotonic(io) + std.time.ns_per_s;
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
    const deadline_ns = clock.monotonic(io) + std.time.ns_per_s;
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
    var select = std.Io.Select(Completion).init(io, &storage);
    defer select.cancelDiscard();

    try std.testing.expectEqual(
        Update.schedule,
        scheduler.update(io, clock.monotonic(io) + std.time.ns_per_s),
    );
    try select.concurrent(.done, wait, .{ io, &scheduler });
    try std.testing.expectEqual(Update.retained, scheduler.update(io, null));
    try std.testing.expectEqual(Update.retained, scheduler.update(io, clock.monotonic(io)));

    switch (try select.await()) {
        .done => |result| try scheduler.complete(result),
    }
    try std.testing.expect(!scheduler.pending);
}

test "earliest deadline updates retain null unchanged and later requests without waking" {
    const io = std.testing.io;
    const first = clock.monotonic(io) + std.time.ns_per_s;
    const later = first + std.time.ns_per_s;
    var scheduler: Scheduler = .{};

    try std.testing.expectEqual(Update.schedule, scheduler.updateEarlier(io, first));
    for ([_]?u64{ null, first, later }) |requested| {
        try std.testing.expectEqual(Update.retained, scheduler.updateEarlier(io, requested));
        try std.testing.expectEqual(first, scheduler.deadline_ns.load(.acquire));
        try std.testing.expect(scheduler.pending);
        try std.testing.expect(!scheduler.wake.isSet());
    }
}

test "an earlier deadline wakes the existing worker instead of scheduling another" {
    const io = std.testing.io;
    const earlier = clock.monotonic(io);
    const first = earlier + std.time.ns_per_s;
    var scheduler: Scheduler = .{};

    try std.testing.expectEqual(Update.schedule, scheduler.updateEarlier(io, first));
    try std.testing.expectEqual(Update.retained, scheduler.updateEarlier(io, earlier));
    try std.testing.expectEqual(earlier, scheduler.deadline_ns.load(.acquire));
    try std.testing.expect(scheduler.pending);
    try std.testing.expect(scheduler.wake.isSet());
    try wait(io, &scheduler);
}

test "an expired queued wake retains ownership until completion and then idles or rearms" {
    const io = std.testing.io;
    const expired = clock.monotonic(io);
    const later = expired + std.time.ns_per_s;
    var scheduler: Scheduler = .{};

    try std.testing.expectEqual(Update.schedule, scheduler.updateEarlier(io, expired));
    try wait(io, &scheduler);

    // The worker has returned, but its owner has not consumed the completion.
    for ([_]?u64{ later, null, later }) |requested| {
        try std.testing.expectEqual(Update.retained, scheduler.updateEarlier(io, requested));
        try std.testing.expectEqual(expired, scheduler.deadline_ns.load(.acquire));
        try std.testing.expect(scheduler.pending);
        try std.testing.expect(!scheduler.wake.isSet());
    }

    try scheduler.complete({});
    try std.testing.expectEqual(Update.idle, scheduler.updateEarlier(io, null));
    try std.testing.expectEqual(no_deadline, scheduler.deadline_ns.load(.acquire));
    try std.testing.expect(!scheduler.pending);
    try std.testing.expect(!scheduler.wake.isSet());

    try std.testing.expectEqual(Update.schedule, scheduler.updateEarlier(io, later));
    try std.testing.expectEqual(later, scheduler.deadline_ns.load(.acquire));
    try std.testing.expect(scheduler.pending);
    try std.testing.expect(!scheduler.wake.isSet());
}
