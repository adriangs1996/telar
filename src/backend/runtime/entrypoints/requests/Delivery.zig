const Delivery = @This();

context: *anyopaque,
pump_all_fn: *const fn (*anyopaque) void,

/// Makes newly queued notifications and confirmation eligible for socket
/// delivery after their synchronous transaction is complete.
///
/// ```zig
/// delivery.pumpAll();
/// ```
pub fn pumpAll(delivery: Delivery) void {
    delivery.pump_all_fn(delivery.context);
}
