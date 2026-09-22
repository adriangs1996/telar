//! What a lifecycle report says beyond its state: why the agent is blocked
//! and one line naming the moment. It is shown only while that report is
//! the evidence the projection follows.

const core = @import("telar-core");
const EventLine = @import("EventLine.zig");
const ReportDetail = @This();

blocked_reason: core.AgentBlockedReason = .none,
event: EventLine = .{},
