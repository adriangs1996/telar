const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const timers = @import("timers.zig");
/// Arms one client `Scheduler` on the adapter's event loop. The adapter waits
/// with `deadline_timer.wait` and delivers the completion named by the kind.
const HostTimers = @This();

context: *anyopaque,
arm_fn: *const fn (*anyopaque, timers.Kind, *core.DeadlineScheduler) anyerror!void,
/// Hosts with a presentation clock schedule only their visible animations.
animation_clock: timers.AnimationClock = .model,

/// Example: `.schedule => try client.timers.arm(.notification, scheduler),`.
pub fn arm(self: HostTimers, kind: timers.Kind, scheduler: *core.DeadlineScheduler) !void {
    return self.arm_fn(self.context, kind, scheduler);
}

/// Keeps one timer for the earliest deadline or an immediate pending callback.
/// A rejected timer releases its reservation so the next attempt can retry.
/// Example: `try timers.rearmBars(io, &state);`
pub fn rearmBars(self: HostTimers, io: std.Io, state: *data.BarUpdatesState) !void {
    const deadline_ns = if (state.pending_callbacks != 0) core.monotonic(io) else state.nextDeadline();

    switch (state.scheduler.update(io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => self.arm(.bar, &state.scheduler) catch |err| {
            state.scheduler.schedulingFailed();

            return err;
        },
    }
}

test "bar timer scheduling retries failure and reuses one pending worker" {
    const Timer = struct {
        reject: bool = true,
        calls: usize = 0,

        fn arm(raw: *anyopaque, kind: timers.Kind, scheduler: *core.DeadlineScheduler) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(.bar, kind);
            try std.testing.expect(scheduler.pending);

            if (self.reject) {
                return error.TimerBusy;
            }
        }
    };

    var timer: Timer = .{};
    const host_timers: HostTimers = .{
        .context = &timer,
        .arm_fn = Timer.arm,
    };
    var state: data.BarUpdatesState = .{};
    const io = std.testing.io;
    try host_timers.rearmBars(io, &state);
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    state.pending_callbacks = data.bar_values.Position.bottom_left.bit();
    try std.testing.expectError(error.TimerBusy, host_timers.rearmBars(io, &state));
    try std.testing.expect(!state.scheduler.pending);
    timer.reject = false;
    try host_timers.rearmBars(io, &state);
    try std.testing.expect(state.scheduler.pending);
    const immediate = state.scheduler.deadline_ns.load(.acquire);
    try std.testing.expect(immediate <= core.monotonic(io));
    try host_timers.rearmBars(io, &state);
    try std.testing.expectEqual(@as(usize, 2), timer.calls);

    state.pending_callbacks = 0;
    state.deadlines[@intFromEnum(data.bar_values.Position.bottom_left)] = immediate + std.time.ns_per_s;
    try host_timers.rearmBars(io, &state);
    try std.testing.expectEqual(immediate + std.time.ns_per_s, state.scheduler.deadline_ns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), timer.calls);
    state.synchronize(
        .{
            .generation = 2,
            .configuration = null,
            .now_ns = core.monotonic(io),
        },
    );
    try host_timers.rearmBars(io, &state);
    try std.testing.expectEqual(data.bar_timing.no_deadline, state.scheduler.deadline_ns.load(.acquire));
    try state.scheduler.complete({});
    try host_timers.rearmBars(io, &state);
    try std.testing.expectEqual(@as(usize, 2), timer.calls);
    try std.testing.expect(!state.scheduler.pending);
}
