const kitty_protocol = @import("kitty_protocol");
const core = @import("telar-core");
const SharedFrameKey = @import("SharedFrameKey.zig");
const media = @import("media.zig");
const SharedFrameControl = @This();

key: SharedFrameKey,
byte_len: usize,
format: kitty_protocol.Format,
width: u32,
height: u32,
medium: media.Medium,
