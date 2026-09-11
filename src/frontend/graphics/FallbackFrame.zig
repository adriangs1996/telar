const PartialTransmission = @import("PartialTransmission.zig");
const kitty_delivery = @import("kitty_delivery.zig");
const FallbackFrame = @This();

partial: PartialTransmission,
image: kitty_delivery.Store.ImageEntry,
