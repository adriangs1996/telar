const kitty_protocol = @import("kitty_protocol");
const core = @import("telar-core");
const SharedFrameKey = @import("SharedFrameKey.zig");
const media = @import("media.zig");
const SharedFrame = @This();

start: usize,
end: usize,
/// The KGP command inside the envelope, APC introducer to terminator.
apc_start: usize,
apc_end: usize,
payload_start: usize,
payload_end: usize,
key: SharedFrameKey,
byte_len: usize,
format: kitty_protocol.Format,
width: u32,
height: u32,
medium: media.Medium,
