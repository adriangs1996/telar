const Trace = @import("Trace.zig");
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const PaneResizeScheduler = @import("../application/commands/PaneResizeScheduler.zig");
const Pane = @import("../../pane/Pane.zig");
const std = @import("std");
const PaneFixtureType = @import("PaneFixture.zig");
const SchedulerCapture = @This();

trace: *Trace,
attachments: *AttachmentStoreType,
expected_size: TerminalSizeType,
observation_failure: ?anyerror = null,
media_failure: ?anyerror = null,
response_failure: ?anyerror = null,
observation_saw_resized_pane: bool = false,
observation_saw_old_attachment: bool = false,
response_saw_resized_attachment: bool = false,

pub fn scheduler(capture: *SchedulerCapture) PaneResizeScheduler {
    return .{
        .context = capture,
        .observation = scheduleObservation,
        .media = scheduleMedia,
        .response = scheduleResponse,
    };
}

fn scheduleObservation(context: *anyopaque, pane: *Pane) !void {
    const capture: *SchedulerCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.observation);
    capture.observation_saw_resized_pane = std.meta.eql(pane.size, capture.expected_size);
    const attachment = capture.attachments.find(pane.id) orelse return error.MissingAttachment;
    capture.observation_saw_old_attachment = attachment.cells.acknowledged.w == PaneFixtureType.initial_size.cols and
        attachment.cells.acknowledged.h == PaneFixtureType.initial_size.rows;

    if (capture.observation_failure) |failure| {
        return failure;
    }
}

fn scheduleMedia(context: *anyopaque, _: *Pane) !void {
    const capture: *SchedulerCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.media);

    if (capture.media_failure) |failure| {
        return failure;
    }
}

fn scheduleResponse(context: *anyopaque, pane: *Pane) !void {
    const capture: *SchedulerCapture = @ptrCast(@alignCast(context));
    capture.trace.record(.response);
    const attachment = capture.attachments.find(pane.id) orelse return error.MissingAttachment;
    capture.response_saw_resized_attachment = attachment.cells.acknowledged.w == capture.expected_size.cols and
        attachment.cells.acknowledged.h == capture.expected_size.rows;

    if (capture.response_failure) |failure| {
        return failure;
    }
}
