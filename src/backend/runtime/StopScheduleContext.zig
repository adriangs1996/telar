const StopScheduleContext = @This();
const Sources = @import("Sources.zig");
const stop_signal_mod = @import("lifecycle/root.zig").stop_signal;
const source_namespace = @import("event_sources.zig");
sources: *Sources,

pub fn scheduler(context: *StopScheduleContext) stop_signal_mod.Scheduler {
    return .{ .context = context, .schedule_fn = schedule };
}

fn schedule(context_value: *anyopaque, queue: *source_namespace.Io.Queue(u8)) !void {
    const context: *StopScheduleContext = @ptrCast(@alignCast(context_value));
    try context.sources.select.concurrent(.stopped, stop_signal_mod.wait, .{ context.sources.io, queue });
}
