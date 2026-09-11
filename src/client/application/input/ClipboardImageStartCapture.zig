const StartCapture = @This();
const client_model = @import("../../root.zig").model;
const StartEffects = @import("ClipboardImageStartEffects.zig");
const std = @import("std");
model: *const client_model.Model,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *StartCapture) StartEffects {
    return .{ .context = capture, .schedule = schedule };
}

fn schedule(raw_context: *anyopaque, expected: client_model.ClipboardCapture) !void {
    const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(capture.model.clipboardCapture().?, expected);
    if (capture.fail) {
        return error.CaptureScheduleFailed;
    }
}
