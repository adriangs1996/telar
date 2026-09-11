const Recipient = @This();
const delivery_mod = @import("../delivery/root.zig");
active: bool,
delivery: *delivery_mod.Delivery,
