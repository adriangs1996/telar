const vm_support = @import("vm_support.zig");
const Meter = @This();

used: usize = 0,
limit: usize = vm_support.default_memory_limit,
