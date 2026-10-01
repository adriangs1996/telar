//! One clipboard capture worker's answer: the capture, or the error that
//! stopped it with the limit it reached, which the client flow reports.
const core = @import("telar-core");
const data = @import("../../model.zig");
const Capture = @import("../../attachments/Capture.zig");
const Completion = @This();

execution_id: data.ClipboardCaptureId,
result: anyerror!*Capture,
/// The attachment limit the worker stopped at, when one did.
limit: ?core.LimitReach = null,
