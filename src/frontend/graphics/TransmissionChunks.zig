const ImageType = @import("telar-core").Image;
const TransmissionChunks = @This();

external_id: u32,
image: ImageType,
pixels: []const u8,
start_offset: usize,
budget: usize,
compressed: bool,
