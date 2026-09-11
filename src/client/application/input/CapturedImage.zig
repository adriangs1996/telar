const CapturedImage = @This();
const client_model = @import("../../root.zig").model;
const attachments = @import("../../attachments/root.zig");
execution_id: client_model.ClipboardCaptureId,
result_id: client_model.ClipboardCaptureId,
target: attachments.Target,
