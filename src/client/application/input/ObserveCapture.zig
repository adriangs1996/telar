const ObserveCapture = @This();
const attachments = @import("../../attachments/root.zig");
const ObserveEffects = @import("ObserveEffects.zig");
const std = @import("std");
target: attachments.Target,
marker: ?attachments.Id = null,
pending_marker: bool = false,
continues: bool = false,
removed: ?attachments.Id = null,
prompt_removed: bool = false,

pub fn effects(capture: *ObserveCapture) ObserveEffects {
    return .{
        .context = capture,
        .visible_target = visibleTarget,
        .marker_at_cursor = markerAtCursor,
        .pending_marker_at_cursor = pendingMarkerAtCursor,
        .prompt_continues = promptContinues,
        .remove = remove,
        .remove_prompt = removePrompt,
    };
}

fn visibleTarget(raw_context: *anyopaque) ?attachments.Target {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.target;
}

fn markerAtCursor(raw_context: *anyopaque, _: attachments.MarkerDeletion) ?attachments.Id {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.marker;
}

fn pendingMarkerAtCursor(raw_context: *anyopaque, _: attachments.MarkerDeletion) bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.pending_marker;
}

fn promptContinues(raw_context: *anyopaque, _: attachments.Target) bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.continues;
}

fn remove(raw_context: *anyopaque, id: attachments.Id) ?bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));
    capture.removed = id;

    return false;
}

fn removePrompt(raw_context: *anyopaque, target: attachments.Target) ?bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));
    std.debug.assert(std.meta.eql(capture.target, target));
    capture.prompt_removed = true;

    return true;
}
