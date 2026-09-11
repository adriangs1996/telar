const types = @import("../../model/types.zig");
const TargetType = @import("../../attachments/AttachmentTarget.zig");
const CapturedImage = @This();

execution_id: types.ClipboardCaptureId,
result_id: types.ClipboardCaptureId,
target: TargetType,
