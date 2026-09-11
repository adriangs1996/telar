const Scheduler = @This();
const source_namespace = @import("stop_signal.zig");
context: *anyopaque,
schedule_fn: *const fn (*anyopaque, *source_namespace.Io.Queue(u8)) anyerror!void,

pub fn schedule(scheduler: Scheduler, queue: *source_namespace.Io.Queue(u8)) !void {
    return scheduler.schedule_fn(scheduler.context, queue);
}
