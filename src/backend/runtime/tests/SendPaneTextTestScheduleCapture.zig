const ScheduleCapture = @This();
const pane_input_commands = @import("../application/commands/pane_input.zig");
const source_namespace = @import("send_pane_text_test.zig");
observation_calls: usize = 0,
input_calls: usize = 0,
queued: ?[]const u8 = null,
queued_storage: [256]u8 = undefined,

pub fn scheduler(capture: *ScheduleCapture) pane_input_commands.Scheduler {
    return .{
        .context = capture,
        .observation = scheduleObservation,
        .input = scheduleInput,
    };
}

fn scheduleObservation(context: *anyopaque, _: *source_namespace.Pane) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.observation_calls += 1;
}

fn scheduleInput(context: *anyopaque, pane: *source_namespace.Pane) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.input_calls += 1;
    const chunk = pane.input_queue.nextChunk() orelse return error.MissingQueuedInput;
    @memcpy(capture.queued_storage[0..chunk.len], chunk);
    capture.queued = capture.queued_storage[0..chunk.len];
}
