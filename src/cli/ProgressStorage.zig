const std = @import("std");
const core = @import("telar-core");
/// Buffers the report borrows.
// SAFETY: hook_progress passes root as output to linked-worktree discovery and uses only the returned slice.
root: [std.fs.max_path_bytes]u8 = undefined,
// SAFETY: hook_progress passes head as output to linked-worktree discovery and uses only the returned slice.
head: [256]u8 = undefined,
// SAFETY: hook_progress sanitizes the message into this buffer before borrowing the returned prefix.
message: [core.max_agent_final_message_bytes]u8 = undefined,
// SAFETY: hook_progress formats the plan line into this buffer before borrowing the returned prefix.
step: [core.max_agent_plan_step_bytes]u8 = undefined,
