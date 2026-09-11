const Completion = @This();
const client_model = @import("telar-client").model;
const attachments = @import("../../../attachments/root.zig");
execution_id: client_model.ClipboardCaptureId,
result: anyerror!*attachments.Capture,
