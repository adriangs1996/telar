const kitty_protocol = @import("kitty_protocol");
const PlacementCommand = @This();

image_id: u32,
placement_id: u32,
value: kitty_protocol.OutputPlacement,
z: i32,
