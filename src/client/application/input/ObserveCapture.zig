const TargetType = @import("../../attachments/AttachmentTarget.zig");
const types = @import("../../attachments/types.zig");
const ObserveEffects = @import("ObserveEffects.zig");
const std = @import("std");
const ObserveCapture = @This();

target: TargetType,
marker: ?types.Id = null,
pending_marker: bool = false,
continues: bool = false,
removed: ?types.Id = null,
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

fn visibleTarget(raw_context: *anyopaque) ?TargetType {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.target;
}

fn markerAtCursor(raw_context: *anyopaque, _: types.MarkerDeletion) ?types.Id {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.marker;
}

fn pendingMarkerAtCursor(raw_context: *anyopaque, _: types.MarkerDeletion) bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.pending_marker;
}

fn promptContinues(raw_context: *anyopaque, _: TargetType) bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

    return capture.continues;
}

fn remove(raw_context: *anyopaque, id: types.Id) ?bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));
    capture.removed = id;

    return false;
}

fn removePrompt(raw_context: *anyopaque, target: TargetType) ?bool {
    const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));
    std.debug.assert(std.meta.eql(capture.target, target));
    capture.prompt_removed = true;

    return true;
}
