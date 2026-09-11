const std = @import("std");
const deadline_timer = @import("deadline_timer.zig");
const Scheduler = @This();

deadline_ns: std.atomic.Value(u64) = .init(deadline_timer.no_deadline),
wake: std.Io.Event = .unset,
pending: bool = false,

/// Replaces the current deadline and reports whether the caller must
/// schedule the one worker.
///
/// ```zig
/// if (scheduler.update(io, deadline_ns) == .schedule) startWorker();
/// ```
pub fn update(scheduler: *Scheduler, io: std.Io, deadline_ns: ?u64) deadline_timer.Update {
    const replacement = deadline_ns orelse deadline_timer.no_deadline;
    const previous = scheduler.deadline_ns.load(.acquire);
    scheduler.deadline_ns.store(replacement, .release);
    if (scheduler.pending) {
        if (previous != replacement) {
            scheduler.wake.set(io);
        }

        return .retained;
    }
    if (deadline_ns == null) {
        return .idle;
    }

    scheduler.wake.reset();
    scheduler.pending = true;

    return .schedule;
}

/// Releases the reservation when the caller could not schedule its worker.
///
/// ```zig
/// scheduler.schedulingFailed();
/// ```
pub fn schedulingFailed(scheduler: *Scheduler) void {
    scheduler.pending = false;
}

/// Releases the completed worker before propagating its result.
///
/// ```zig
/// try scheduler.complete(result);
/// ```
pub fn complete(scheduler: *Scheduler, result: anyerror!void) !void {
    scheduler.pending = false;

    try result;
}
