const ClipboardCaptureId = @import("../types/ClipboardCaptureId.zig").ClipboardCaptureId;
const AttachmentTarget = @import("../attachments/AttachmentTarget.zig");
const ClipboardCapture = @This();

id: ClipboardCaptureId,
target: AttachmentTarget,
