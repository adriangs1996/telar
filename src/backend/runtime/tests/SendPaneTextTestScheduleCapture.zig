const PaneInputScheduler = @import("../application/commands/PaneInputScheduler.zig");
const PaneType = @import("../../pane/Pane.zig");
const ScheduleCapture = @This();

observation_calls: usize = 0,
input_calls: usize = 0,
queued: ?[]const u8 = null,
queued_storage: [256]u8 = undefined,

pub fn scheduler(capture: *ScheduleCapture) PaneInputScheduler {
    return .{
        .context = capture,
        .observation = scheduleObservation,
        .input = scheduleInput,
    };
}

fn scheduleObservation(context: *anyopaque, _: *PaneType) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.observation_calls += 1;
}

fn scheduleInput(context: *anyopaque, pane: *PaneType) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.input_calls += 1;
    const chunk = pane.input_queue.nextChunk() orelse return error.MissingQueuedInput;
    @memcpy(capture.queued_storage[0..chunk.len], chunk);
    capture.queued = capture.queued_storage[0..chunk.len];
}
