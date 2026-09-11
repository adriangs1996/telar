const ScheduleCapture = @This();
const source_namespace = @import("pane_input_test.zig");
const pane_input_commands = @import("../application/commands/pane_input.zig");
const std = @import("std");
steps: [2]source_namespace.ScheduleStep = undefined,
len: usize = 0,
observation_failure: ?anyerror = null,
input_failure: ?anyerror = null,
observation_saw_history: bool = false,
observation_saw_empty_input_queue: bool = false,
input_saw_history: bool = false,
expected_input: ?[]const u8 = null,
input_matched: bool = false,

pub fn scheduler(capture: *ScheduleCapture) pane_input_commands.Scheduler {
    return .{
        .context = capture,
        .observation = scheduleObservation,
        .input = scheduleInput,
    };
}

fn scheduleObservation(context: *anyopaque, pane: *source_namespace.Pane) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.record(.observation);
    capture.observation_saw_history = pane.history_observer.hasPending();
    capture.observation_saw_empty_input_queue = pane.input_queue.nextChunk() == null;

    if (capture.observation_failure) |failure| {
        return failure;
    }
}

fn scheduleInput(context: *anyopaque, pane: *source_namespace.Pane) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.record(.input);
    capture.input_saw_history = pane.history_observer.hasPending();

    if (capture.expected_input) |expected| {
        const queued = pane.input_queue.nextChunk() orelse return error.MissingQueuedInput;
        capture.input_matched = std.mem.eql(u8, expected, queued);
    }

    if (capture.input_failure) |failure| {
        return failure;
    }
}

fn record(capture: *ScheduleCapture, step: source_namespace.ScheduleStep) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}
