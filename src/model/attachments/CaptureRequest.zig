const model_data = @import("../model.zig");
const CaptureRequest = @This();

target: model_data.AttachmentTarget,
sequence: u64,
marker_policy: model_data.AttachmentMarkerPolicy = .ordered,
