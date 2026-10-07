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
