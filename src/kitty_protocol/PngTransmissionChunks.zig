const PngTransmissionChunks = @This();

image_id: u32,
png: []const u8,
start_offset: usize,
budget: usize,
