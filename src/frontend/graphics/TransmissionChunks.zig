const TransmissionChunks = @This();
const source_namespace = @import("kitty_codec.zig");
external_id: u32,
image: source_namespace.graphics.Image,
pixels: []const u8,
start_offset: usize,
budget: usize,
compressed: bool,
