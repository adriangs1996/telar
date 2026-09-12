const ClipboardCaptureIdType = @import("../../model/types.zig").ClipboardCaptureId;
const CaptureType = @import("../../attachments/Capture.zig");
const Completion = @This();

execution_id: ClipboardCaptureIdType,
result: anyerror!*CaptureType,
