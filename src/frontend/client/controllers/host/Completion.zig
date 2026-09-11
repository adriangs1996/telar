const ClipboardCaptureIdType = @import("telar-client").ClipboardCaptureId;
const CaptureType = @import("telar-client").Capture;
const Completion = @This();

execution_id: ClipboardCaptureIdType,
result: anyerror!*CaptureType,
