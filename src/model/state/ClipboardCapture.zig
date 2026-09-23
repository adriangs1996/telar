const types = @import("types.zig");
const AttachmentTarget = @import("../attachments/AttachmentTarget.zig");
const ClipboardCapture = @This();

id: types.ClipboardCaptureId,
target: AttachmentTarget,
