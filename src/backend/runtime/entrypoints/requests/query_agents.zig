//! Protocol controller for one-shot agent snapshot queries. The delivery pump
//! answers with the same enriched `agent_snapshot` that subscribers receive.

const std = @import("std");
const schema = @import("telar-core").schema;

/// Builds a statically dispatched agent-query controller.
///
/// ```zig
/// const QueryAgentsController = Controller(*Delivery);
/// var controller = QueryAgentsController.init(&delivery);
/// ```
pub fn Controller(comptime Subscriber: type) type {
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

const StubSubscriber = struct {
    call_count: usize = 0,

    fn requestAgentSnapshot(stub: *StubSubscriber) void {
        stub.call_count += 1;
    }
};

test "Controller schedules one snapshot per query" {
    var stub: StubSubscriber = .{};
    var controller = Controller(*StubSubscriber).init(&stub);

    controller.queryAgents(.{ .request_id = @enumFromInt(1) });
    controller.queryAgents(.{ .request_id = @enumFromInt(2) });

    try std.testing.expectEqual(@as(usize, 2), stub.call_count);
}
