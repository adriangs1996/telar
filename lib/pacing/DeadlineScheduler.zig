const std = @import("std");
const deadline_timer = @import("deadline_timer.zig");
const DeadlineScheduler = @This();

deadline_ns: std.atomic.Value(u64) = .init(deadline_timer.no_deadline),
wake: std.Io.Event = .unset,
pending: bool = false,

/// Replaces the current deadline and reports whether the caller must
/// schedule the one worker.
///
/// ```zig
/// if (scheduler.update(io, deadline_ns) == .schedule) startWorker();
/// ```
pub fn update(self: *DeadlineScheduler, io: std.Io, deadline_ns: ?u64) deadline_timer.Update {
    const replacement = deadline_ns orelse deadline_timer.no_deadline;
    const previous = self.deadline_ns.load(.acquire);
    self.deadline_ns.store(replacement, .release);
    if (self.pending) {
        if (previous != replacement) {
            self.wake.set(io);
        }

        return .retained;
    }
    if (deadline_ns == null) {
        return .idle;
    }

    self.wake.reset();
    self.pending = true;

    return .schedule;
}

/// Keeps an armed wake unless new work needs an earlier deadline. Removing
/// work or moving it later leaves at most one obsolete wake; its owner must
/// complete that wake and re-evaluate current work before scheduling again.
///
/// ```zig
/// if (scheduler.updateEarlier(io, earliest_pending_ns) == .schedule) startWorker();
/// ```
pub fn updateEarlier(self: *DeadlineScheduler, io: std.Io, deadline_ns: ?u64) deadline_timer.Update {
    if (self.pending) {
        const requested = deadline_ns orelse return .retained;
        const armed = self.deadline_ns.load(.acquire);
        if (armed <= requested) {
            return .retained;
        }
    }

    return self.update(io, deadline_ns);
}

/// Releases the reservation when the caller could not schedule its worker.
///
/// ```zig
/// scheduler.schedulingFailed();
/// ```
pub fn schedulingFailed(self: *DeadlineScheduler) void {
    self.pending = false;
}

/// Releases the completed worker before propagating its result.
///
/// ```zig
/// try scheduler.complete(result);
/// ```
pub fn complete(self: *DeadlineScheduler, result: anyerror!void) !void {
    self.pending = false;

    try result;
}
