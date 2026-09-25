const ClipboardCaptureId = @import("ClipboardCaptureId.zig").ClipboardCaptureId;
const AttachmentTarget = @import("../attachments/AttachmentTarget.zig");
const ClipboardCapture = @This();

id: ClipboardCaptureId,
target: AttachmentTarget,
