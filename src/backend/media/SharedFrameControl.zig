const SharedFrameKey = @import("SharedFrameKey.zig");
const FormatType = @import("telar-core").Format;
const media = @import("media.zig");
const SharedFrameControl = @This();

key: SharedFrameKey,
byte_len: usize,
format: FormatType,
width: u32,
height: u32,
medium: media.Medium,
