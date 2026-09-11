const pane_input_test = @import("pane_input_test.zig");
const PaneInputScheduler = @import("../application/commands/PaneInputScheduler.zig");
const PaneType = @import("../../pane/Pane.zig");
const std = @import("std");
const ScheduleCapture = @This();

steps: [2]pane_input_test.ScheduleStep = undefined,
len: usize = 0,
observation_failure: ?anyerror = null,
input_failure: ?anyerror = null,
observation_saw_history: bool = false,
observation_saw_empty_input_queue: bool = false,
input_saw_history: bool = false,
expected_input: ?[]const u8 = null,
input_matched: bool = false,

pub fn scheduler(capture: *ScheduleCapture) PaneInputScheduler {
    return .{
        .context = capture,
        .observation = scheduleObservation,
        .input = scheduleInput,
    };
}

fn scheduleObservation(context: *anyopaque, pane: *PaneType) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.record(.observation);
    capture.observation_saw_history = pane.history_observer.hasPending();
    capture.observation_saw_empty_input_queue = pane.input_queue.nextChunk() == null;

    if (capture.observation_failure) |failure| {
        return failure;
    }
}

fn scheduleInput(context: *anyopaque, pane: *PaneType) !void {
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

fn record(capture: *ScheduleCapture, step: pane_input_test.ScheduleStep) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}
