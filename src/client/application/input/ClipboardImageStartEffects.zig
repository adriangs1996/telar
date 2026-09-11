const ClipboardCaptureType = @import("../../model/ClipboardCapture.zig");
const StartEffects = @This();

context: *anyopaque,
schedule: *const fn (*anyopaque, ClipboardCaptureType) anyerror!void,
