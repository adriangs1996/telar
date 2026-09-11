const SharedFrame = @This();
const SharedFrameKey = @import("SharedFrameKey.zig");
const core = @import("telar-core");
const source_namespace = @import("root.zig");
start: usize,
end: usize,
/// The KGP command inside the envelope, APC introducer to terminator.
apc_start: usize,
apc_end: usize,
payload_start: usize,
payload_end: usize,
key: SharedFrameKey,
byte_len: usize,
format: core.graphics.Format,
width: u32,
height: u32,
medium: source_namespace.Medium,
