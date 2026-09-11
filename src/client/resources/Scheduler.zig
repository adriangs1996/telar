const Scheduler = @This();
const std = @import("std");
const source_namespace = @import("deadline_timer.zig");
deadline_ns: std.atomic.Value(u64) = .init(source_namespace.no_deadline),
wake: source_namespace.Io.Event = .unset,
pending: bool = false,

/// Replaces the current deadline and reports whether the caller must
/// schedule the one worker.
///
/// ```zig
/// if (scheduler.update(io, deadline_ns) == .schedule) startWorker();
/// ```
pub fn update(scheduler: *Scheduler, io: source_namespace.Io, deadline_ns: ?u64) source_namespace.Update {
    const replacement = deadline_ns orelse source_namespace.no_deadline;
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
