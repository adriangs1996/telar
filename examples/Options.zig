const Options = @This();
const source_namespace = @import("frame_source.zig");
width: u32 = 3840,
height: u32 = 2160,
fps: u32 = 120,
seconds: u32 = 20,
image_id: u32 = 1,
transport: source_namespace.Transport = .shm,
