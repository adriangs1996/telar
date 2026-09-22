const core = @import("telar-core");
const Transmission = @This();

external_id: u32,
image: core.Image,
pixels: []const u8,
