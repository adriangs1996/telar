const CaptureRequest = @This();
const Target = @import("Target.zig");
const source_namespace = @import("types.zig");
target: Target,
sequence: u64,
marker_policy: source_namespace.MarkerPolicy = .ordered,
