const ClipboardCaptureType = @import("ClipboardCapture.zig");
const TargetType = @import("../attachments/AttachmentTarget.zig");
const types = @import("types.zig");
const std = @import("std");
const State = @This();

clipboard_capture: ?ClipboardCaptureType = null,
next_clipboard_capture_id: u64 = 1,

/// Example: `const result = state.clipboardCapture(...);`.
pub fn clipboardCapture(state: *const State) ?ClipboardCaptureType {
    return state.clipboard_capture;
}

/// Example: `const result = state.beginClipboardCapture(...);`.
pub fn beginClipboardCapture(state: *State, target: TargetType) !?ClipboardCaptureType {
    if (state.clipboard_capture != null) {
        return null;
    }
    if (state.next_clipboard_capture_id == 0) {
        return error.ClipboardCaptureIdExhausted;
    }

    try target.validate();
    const capture: ClipboardCaptureType = .{
        .id = @enumFromInt(state.next_clipboard_capture_id),
        .target = target,
    };
    state.next_clipboard_capture_id +%= 1;
    state.clipboard_capture = capture;

    return capture;
}

/// Example: `const result = state.finishClipboardCapture(...);`.
pub fn finishClipboardCapture(state: *State, id: types.ClipboardCaptureId) ?ClipboardCaptureType {
    const capture = state.clipboard_capture orelse return null;
    if (capture.id != id) {
        return null;
    }

    state.clipboard_capture = null;
    return capture;
}

/// Example: `const result = state.cancelClipboardCapture(...);`.
pub fn cancelClipboardCapture(state: *State, target: TargetType) bool {
    const capture = state.clipboard_capture orelse return false;
    if (!std.meta.eql(capture.target, target)) {
        return false;
    }

    state.clipboard_capture = null;
    return true;
}
