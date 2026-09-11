const CompletionCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("clipboard_image.zig");
const CompletionEffects = @import("ClipboardImageCompletionEffects.zig");
model: *const client_model.Model,
events: [2]source_namespace.CompletionEvent = undefined,
event_count: usize = 0,
observed_finished: bool = false,
layout_changed: bool = false,
fail_adopt: bool = false,
fail_resize: bool = false,

pub fn port(capture: *CompletionCapture) CompletionEffects {
    return .{
        .context = capture,
        .adopt = adopt,
        .resize = resize,
    };
}

fn adopt(raw_context: *anyopaque) !bool {
    const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .adopt;
    capture.event_count += 1;
    capture.observed_finished = capture.model.clipboardCapture() == null;
    if (capture.fail_adopt) {
        return error.AttachmentAdoptionFailed;
    }

    return capture.layout_changed;
}

fn resize(raw_context: *anyopaque) !void {
    const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .resize;
    capture.event_count += 1;
    capture.observed_finished = capture.observed_finished and
        capture.model.clipboardCapture() == null;
    if (capture.fail_resize) {
        return error.AttachmentResizeFailed;
    }
}
