//! Protocol controller for opening a client's level-triggered runtime-state
//! subscription. The normal delivery pump emits current and future revisions.

const std = @import("std");
const schema = @import("telar-core").schema;

/// Builds a statically dispatched runtime-state subscription controller.
///
/// ```zig
/// const RuntimeStateController = Controller(*Delivery);
/// var controller = RuntimeStateController.init(&delivery);
/// ```
pub fn Controller(comptime Subscriber: type) type {
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
        pub inline fn requestRuntimeState(controller: *Self, identity: schema.ClientIdentity) !void {
            try controller.subscriber.requestRuntimeState(identity);
        }
    };
}

const StubSubscriber = struct {
    call_count: usize = 0,

    fn requestRuntimeState(stub: *StubSubscriber, _: schema.ClientIdentity) !void {
        stub.call_count += 1;
    }
};

const TestController = Controller(*StubSubscriber);

test "Controller routes every runtime-state request to the client subscription" {
    var stub: StubSubscriber = .{};
    var controller = TestController.init(&stub);

    try controller.requestRuntimeState(@enumFromInt(7));
    try controller.requestRuntimeState(@enumFromInt(7));

    try std.testing.expectEqual(@as(usize, 2), stub.call_count);
}
