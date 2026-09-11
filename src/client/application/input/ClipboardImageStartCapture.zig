const ModelType = @import("../../model/Model.zig");
const ClipboardImageStartEffects = @import("ClipboardImageStartEffects.zig");
const ClipboardCaptureType = @import("../../model/ClipboardCapture.zig");
const std = @import("std");
const StartCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *StartCapture) ClipboardImageStartEffects {
    return .{ .context = capture, .schedule = schedule };
}

fn schedule(raw_context: *anyopaque, expected: ClipboardCaptureType) !void {
    const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(capture.model.clipboardCapture().?, expected);
    if (capture.fail) {
        return error.CaptureScheduleFailed;
    }
}
