const model_data = @import("../model.zig");
const std = @import("std");
const State = @This();

clipboard_capture: ?model_data.ClipboardCapture = null,
next_clipboard_capture_id: u64 = 1,

/// Example: `const result = state.clipboardCapture(...);`.
pub fn clipboardCapture(state: *const State) ?model_data.ClipboardCapture {
    return state.clipboard_capture;
}

/// Example: `const result = state.beginClipboardCapture(...);`.
pub fn beginClipboardCapture(state: *State, target: model_data.AttachmentTarget) !?model_data.ClipboardCapture {
    if (state.clipboard_capture != null) {
        return null;
    }
    if (state.next_clipboard_capture_id == 0) {
        return error.ClipboardCaptureIdExhausted;
    }

    try target.validate();
    const capture: model_data.ClipboardCapture = .{
        .id = @enumFromInt(state.next_clipboard_capture_id),
        .target = target,
    };
    state.next_clipboard_capture_id +%= 1;
    state.clipboard_capture = capture;

    return capture;
}

/// Example: `const result = state.finishClipboardCapture(...);`.
pub fn finishClipboardCapture(state: *State, id: model_data.ClipboardCaptureId) ?model_data.ClipboardCapture {
    const capture = state.clipboard_capture orelse return null;
    if (capture.id != id) {
        return null;
    }

    state.clipboard_capture = null;
    return capture;
}

/// Example: `const result = state.cancelClipboardCapture(...);`.
pub fn cancelClipboardCapture(state: *State, target: model_data.AttachmentTarget) bool {
    const capture = state.clipboard_capture orelse return false;
    if (!std.meta.eql(capture.target, target)) {
        return false;
    }

    state.clipboard_capture = null;
    return true;
}
