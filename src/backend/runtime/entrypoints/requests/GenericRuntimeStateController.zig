const ClientIdentityType = @import("telar-core").ClientIdentity;

/// Builds a statically dispatched runtime-state subscription controller.
///
/// ```zig
/// const RuntimeStateController = Controller(*Delivery);
/// var controller = RuntimeStateController.init(&delivery);
/// ```
pub fn Type(comptime Subscriber: type) type {
    return struct {
        const Self = @This();

        subscriber: Subscriber,

        /// Creates one controller bound to the requesting client's delivery.
        ///
        /// ```zig
        /// var controller = RuntimeStateController.init(&delivery);
        /// ```
        pub fn init(subscriber: Subscriber) Self {
            return .{ .subscriber = subscriber };
        }

        /// Opens the subscription without resetting revisions already delivered
        /// to this client.
        ///
        /// ```zig
        /// try controller.requestRuntimeState(identity);
        /// ```
        pub inline fn requestRuntimeState(controller: *Self, identity: ClientIdentityType) !void {
            try controller.subscriber.requestRuntimeState(identity);
        }
    };
}
