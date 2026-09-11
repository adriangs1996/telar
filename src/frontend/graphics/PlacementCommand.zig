const OutputPlacementType = @import("kitty_protocol").OutputPlacement;
const PlacementCommand = @This();

image_id: u32,
placement_id: u32,
value: OutputPlacementType,
z: i32,
