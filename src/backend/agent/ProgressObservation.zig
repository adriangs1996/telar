const core = @import("telar-core");
const Identity = @import("Identity.zig");
const PlanChange = @import("PlanChange.zig");
/// What one progress report changes on an agent.
const ProgressObservation = @This();

identity: Identity,
/// The worktree the report resolved to; null keeps the current one.
work_tree: ?core.WorktreeId = null,
plan: PlanChange = .{ .op = .none },
/// Empty keeps the previous answer.
final_message: []const u8 = "",
