const Target = @import("AttachmentTarget.zig");
const types = @import("types.zig");
const CaptureRequest = @This();

target: Target,
sequence: u64,
marker_policy: types.MarkerPolicy = .ordered,
