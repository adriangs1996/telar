const schema = @import("telar-core").schema;
/// Builds a statically dispatched agent-query controller.
///
/// ```zig
/// const QueryAgentsController = Controller(*Delivery);
/// var controller = QueryAgentsController.init(&delivery);
/// ```
pub fn Type(comptime Subscriber: type) type {
    return struct {
        const Self = @This();

        subscriber: Subscriber,

        /// Creates one controller bound to the requesting client's delivery.
        ///
        /// ```zig
        /// var controller = QueryAgentsController.init(&delivery);
        /// ```
        pub fn init(subscriber: Subscriber) Self {
            return .{ .subscriber = subscriber };
        }

        /// Schedules one snapshot. The request identifier is not echoed because
        /// the snapshot message carries its own runtime revision.
        ///
        /// ```zig
        /// controller.queryAgents(request);
        /// ```
        pub inline fn queryAgents(controller: *Self, request: schema.QueryAgents) void {
            _ = request;
            controller.subscriber.requestAgentSnapshot();
        }
    };
}
