const SharedFrameControl = @This();
const SharedFrameKey = @import("SharedFrameKey.zig");
const core = @import("telar-core");
const source_namespace = @import("root.zig");
key: SharedFrameKey,
byte_len: usize,
format: core.graphics.Format,
width: u32,
height: u32,
medium: source_namespace.Medium,
