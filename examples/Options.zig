const frame_source = @import("frame_source.zig");
const Options = @This();

width: u32 = 3840,
height: u32 = 2160,
fps: u32 = 120,
seconds: u32 = 20,
image_id: u32 = 1,
transport: frame_source.Transport = .shm,
