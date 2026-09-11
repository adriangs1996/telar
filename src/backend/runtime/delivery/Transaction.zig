const delivery_namespace = @import("delivery_namespace.zig");
const Transaction = @This();

ticket: u64,
effect: delivery_namespace.Effect,
