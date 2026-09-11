const media = @import("media.zig");
const FrameResource = @This();

encoded_name: []const u8,
byte_len: usize,
limit: usize,
medium: media.Medium,
