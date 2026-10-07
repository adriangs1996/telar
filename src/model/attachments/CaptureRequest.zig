const model_data = @import("../model.zig");

target: model_data.AttachmentTarget,
sequence: u64,
marker_policy: model_data.AttachmentMarkerPolicy = .ordered,
