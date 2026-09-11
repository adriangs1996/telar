const Limits = @This();
const source_namespace = @import("vm_support.zig");
memory: usize = source_namespace.default_memory_limit,
instructions: u64 = source_namespace.default_load_instruction_limit,
deadline_after_ns: u64 = source_namespace.default_load_deadline_ns,
