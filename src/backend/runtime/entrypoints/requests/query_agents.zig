//! Protocol controller for one-shot agent snapshot queries. The delivery pump
//! answers with the same enriched `agent_snapshot` that subscribers receive.

const QueryAgentsStubSubscriber = @import("QueryAgentsStubSubscriber.zig");
const GenericQueryAgentsController = @import("GenericQueryAgentsController.zig").Type;
const std = @import("std");

test "Controller schedules one snapshot per query" {
    var stub: QueryAgentsStubSubscriber = .{};
    var controller = GenericQueryAgentsController(*QueryAgentsStubSubscriber).init(&stub);

    controller.queryAgents(.{ .request_id = @enumFromInt(1) });
    controller.queryAgents(.{ .request_id = @enumFromInt(2) });

    try std.testing.expectEqual(@as(usize, 2), stub.call_count);
}
