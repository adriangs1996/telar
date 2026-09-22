const data = @import("../../model.zig");
const CaptureType = @import("../../attachments/Capture.zig");
const Completion = @This();

execution_id: data.ClipboardCaptureId,
result: anyerror!*CaptureType,
