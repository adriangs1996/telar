const std = @import("std");
const Scheduler = @import("Scheduler.zig");
const ScheduleCapture = @This();

calls: usize = 0,
queue: ?*std.Io.Queue(u8) = null,
failure: ?anyerror = null,

pub fn scheduler(capture: *ScheduleCapture) Scheduler {
    return .{ .context = capture, .schedule_fn = schedule };
}

fn schedule(context: *anyopaque, queue: *std.Io.Queue(u8)) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.queue = queue;

    if (capture.failure) |err| {
        return err;
    }
}
