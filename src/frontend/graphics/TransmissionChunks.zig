const core = @import("telar-core");
const TransmissionChunks = @This();

external_id: u32,
image: core.Image,
pixels: []const u8,
start_offset: usize,
budget: usize,
compressed: bool,
