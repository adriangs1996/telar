const SharedTransmission = @This();
const source_namespace = @import("kitty_codec.zig");
external_id: u32,
image: source_namespace.graphics.Image,
name: []const u8,
