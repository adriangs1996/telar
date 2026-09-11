const std = @import("std");
const Scheduler = @This();

context: *anyopaque,
schedule_fn: *const fn (*anyopaque, *std.Io.Queue(u8)) anyerror!void,

pub fn schedule(scheduler: Scheduler, queue: *std.Io.Queue(u8)) !void {
    return scheduler.schedule_fn(scheduler.context, queue);
}
