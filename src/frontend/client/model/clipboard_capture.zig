//! Owns one asynchronous reservation and rejects obsolete completions.
const std = @import("std");
const types = @import("types.zig");
const attachments = @import("../../attachments/root.zig");
const PluginExecution = types.PluginExecution;
const PluginExecutionId = types.PluginExecutionId;
const ClipboardCapture = types.ClipboardCapture;
const ClipboardCaptureId = types.ClipboardCaptureId;

pub const State = struct {
    clipboard_capture: ?ClipboardCapture = null,
    next_clipboard_capture_id: u64 = 1,

    /// Example: `const result = state.clipboardCapture(...);`.
    pub fn clipboardCapture(state: *const State) ?ClipboardCapture {
        return state.clipboard_capture;
    }

    /// Example: `const result = state.beginClipboardCapture(...);`.
    pub fn beginClipboardCapture(state: *State, target: attachments.Target) !?ClipboardCapture {
        if (state.clipboard_capture != null) {
            return null;
        }
        if (state.next_clipboard_capture_id == 0) {
            return error.ClipboardCaptureIdExhausted;
        }

        try target.validate();
        const capture: ClipboardCapture = .{
            .id = @enumFromInt(state.next_clipboard_capture_id),
            .target = target,
        };
        state.next_clipboard_capture_id +%= 1;
        state.clipboard_capture = capture;

        return capture;
    }

    /// Example: `const result = state.finishClipboardCapture(...);`.
    pub fn finishClipboardCapture(state: *State, id: ClipboardCaptureId) ?ClipboardCapture {
        const capture = state.clipboard_capture orelse return null;
        if (capture.id != id) {
            return null;
        }

        state.clipboard_capture = null;
        return capture;
    }

    /// Example: `const result = state.cancelClipboardCapture(...);`.
    pub fn cancelClipboardCapture(state: *State, target: attachments.Target) bool {
        const capture = state.clipboard_capture orelse return false;
        if (!std.meta.eql(capture.target, target)) {
            return false;
        }

        state.clipboard_capture = null;
        return true;
    }
};
