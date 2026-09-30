const id = @import("../id.zig");
const types = @import("../types.zig");
/// What an agent works on and how far it got, as its hooks report it: the
/// working directory, the linked worktree it resolves to, one plan change and
/// its final answer. Empty strings leave the previous value in place.
const ReportAgentProgress = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
/// The agent whose hook reports; a pane running another agent refuses it.
provider: types.AgentProvider = .unknown,
cwd: []const u8 = "",
/// Top level of the linked worktree `cwd` lies in; empty for a main checkout.
work_tree_path: []const u8 = "",
work_tree_branch: []const u8 = "",
final_message: []const u8 = "",
plan_op: types.AgentPlanOp = .none,
plan_index: u16 = 0,
plan_status: types.AgentPlanStatus = .pending,
plan_done: u16 = 0,
plan_total: u16 = 0,
/// Task subject for `add`, current step for `set`.
plan_text: []const u8 = "",
