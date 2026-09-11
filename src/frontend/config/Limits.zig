const model = @import("model.zig");
const std = @import("std");
const Limits = @This();

memory: usize = model.default_memory_limit,
instructions: u64 = model.default_load_instruction_limit,
deadline_after_ns: u64 = 100 * std.time.ns_per_ms,
