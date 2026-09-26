const std = @import("std");
const core = @import("telar-core");
/// Buffers the report borrows.
const ProgressStorage = @This();

root: [std.fs.max_path_bytes]u8 = undefined,
head: [256]u8 = undefined,
message: [core.max_agent_final_message_bytes]u8 = undefined,
step: [core.max_agent_plan_step_bytes]u8 = undefined,
