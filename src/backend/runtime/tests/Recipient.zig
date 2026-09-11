const DeliveryType = @import("../delivery/Delivery.zig");
const Recipient = @This();

active: bool,
delivery: *DeliveryType,
