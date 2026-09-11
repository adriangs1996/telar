const SchedulerCapture = @This();
const Trace = @import("Trace.zig");
const source_namespace = @import("pane_resize_test.zig");
const pane_resize_commands = @import("../application/commands/pane_resize.zig");
const Pane = @import("../../pane/root.zig").Pane;
const std = @import("std");
trace: *Trace,
attachments: *source_namespace.AttachmentStore,
expected_size: source_namespace.schema.TerminalSize,
observation_failure: ?anyerror = null,
media_failure: ?anyerror = null,
response_failure: ?anyerror = null,
observation_saw_resized_pane: bool = false,
observation_saw_old_attachment: bool = false,
response_saw_resized_attachment: bool = false,

pub fn scheduler(capture: *SchedulerCapture) pane_resize_commands.Scheduler {
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
    capture.observation_saw_old_attachment = attachment.cells.acknowledged.w == source_namespace.PaneFixture.initial_size.cols and
        attachment.cells.acknowledged.h == source_namespace.PaneFixture.initial_size.rows;

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
