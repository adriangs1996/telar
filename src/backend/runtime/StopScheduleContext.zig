const Sources = @import("Sources.zig");
const SchedulerType = @import("lifecycle/Scheduler.zig");
const std = @import("std");
const stop_signal_mod = @import("lifecycle/stop_signal.zig");
const StopScheduleContext = @This();

sources: *Sources,

pub fn scheduler(context: *StopScheduleContext) SchedulerType {
    return .{ .context = context, .schedule_fn = schedule };
}

fn schedule(context_value: *anyopaque, queue: *std.Io.Queue(u8)) !void {
    const context: *StopScheduleContext = @ptrCast(@alignCast(context_value));
    try context.sources.select.concurrent(.stopped, stop_signal_mod.wait, .{ context.sources.io, queue });
}
