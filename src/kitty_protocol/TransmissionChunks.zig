const TransmissionChunks = @This();
const source_namespace = @import("transmission_support.zig");
image_id: u32,
image: source_namespace.Image,
pixels: []const u8,
start_offset: usize,
budget: usize,
compressed: bool,
