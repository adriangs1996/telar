const data = @import("../../model.zig");
const Capture = @import("../../attachments/Capture.zig");
const Completion = @This();

execution_id: data.ClipboardCaptureId,
result: anyerror!*Capture,
