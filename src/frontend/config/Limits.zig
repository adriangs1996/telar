const Limits = @This();
const source_namespace = @import("model.zig");
const std = @import("std");
memory: usize = source_namespace.default_memory_limit,
instructions: u64 = source_namespace.default_load_instruction_limit,
deadline_after_ns: u64 = 100 * std.time.ns_per_ms,
