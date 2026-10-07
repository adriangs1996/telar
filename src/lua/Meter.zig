const vm_support = @import("vm_support.zig");

used: usize = 0,
limit: usize = vm_support.default_memory_limit,
