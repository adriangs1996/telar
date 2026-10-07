const Image = @import("Image.zig");

image_id: u32,
image: Image,
pixels: []const u8,
start_offset: usize,
budget: usize,
compressed: bool,
