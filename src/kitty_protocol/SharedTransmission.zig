const SharedTransmission = @This();
const source_namespace = @import("transmission_support.zig");
image_id: u32,
image: source_namespace.Image,
name: []const u8,
