const PlacementCommand = @This();
const source_namespace = @import("kitty_codec.zig");
image_id: u32,
placement_id: u32,
value: source_namespace.OutputPlacement,
z: i32,
