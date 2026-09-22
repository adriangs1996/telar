const types = @import("types.zig");
const TargetType = @import("../attachments/AttachmentTarget.zig");
const ClipboardCapture = @This();

id: types.ClipboardCaptureId,
target: TargetType,
