const vm_support = @import("vm_support.zig");
const Limits = @This();

memory: usize = vm_support.default_memory_limit,
instructions: u64 = vm_support.default_load_instruction_limit,
deadline_after_ns: u64 = vm_support.default_load_deadline_ns,
