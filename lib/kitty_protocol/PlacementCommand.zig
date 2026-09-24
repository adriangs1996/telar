const OutputPlacement = @import("OutputPlacement.zig");
const PlacementCommand = @This();

image_id: u32,
placement_id: u32,
value: OutputPlacement,
z: i32,
