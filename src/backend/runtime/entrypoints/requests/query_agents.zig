//! Protocol controller for one-shot agent snapshot queries. The delivery pump
//! answers with the same enriched `agent_snapshot` that subscribers receive.

const std = @import("std");
const schema = @import("telar-core").schema;

pub const Controller = @import("GenericQueryAgentsController.zig").Type;

const StubSubscriber = @import("QueryAgentsStubSubscriber.zig");

test "Controller schedules one snapshot per query" {
    var stub: StubSubscriber = .{};
    var controller = Controller(*StubSubscriber).init(&stub);

    controller.queryAgents(.{ .request_id = @enumFromInt(1) });
    controller.queryAgents(.{ .request_id = @enumFromInt(2) });

    try std.testing.expectEqual(@as(usize, 2), stub.call_count);
}
