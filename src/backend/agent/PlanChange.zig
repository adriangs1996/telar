const core = @import("telar-core");
/// One plan change from a progress report.
const PlanChange = @This();

op: core.AgentPlanOp,
index: u16 = 0,
status: core.AgentPlanStatus = .pending,
done: u16 = 0,
total: u16 = 0,
text: []const u8 = "",
