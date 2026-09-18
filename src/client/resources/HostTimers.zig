const core = @import("telar-core");
const SchedulerType = core.DeadlineScheduler;
const timers = @import("timers.zig");
/// Arms one client `Scheduler` on the adapter's event loop. The adapter waits
/// with `deadline_timer.wait` and delivers the completion named by the kind.
const HostTimers = @This();

context: *anyopaque,
arm_fn: *const fn (*anyopaque, timers.Kind, *SchedulerType) anyerror!void,
/// Hosts with a presentation clock schedule only their visible animations.
animation_clock: timers.AnimationClock = .model,

/// Example: `.schedule => try client.timers.arm(.notification, scheduler),`.
pub fn arm(port: HostTimers, kind: timers.Kind, scheduler: *SchedulerType) !void {
    return port.arm_fn(port.context, kind, scheduler);
}
