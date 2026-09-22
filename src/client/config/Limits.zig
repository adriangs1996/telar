const data = @import("model");
const std = @import("std");
const Limits = @This();

memory: usize = data.config_values.default_memory_limit,
instructions: u64 = data.config_values.default_load_instruction_limit,
deadline_after_ns: u64 = 100 * std.time.ns_per_ms,
