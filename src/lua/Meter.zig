const Meter = @This();
const source_namespace = @import("vm_support.zig");
used: usize = 0,
limit: usize = source_namespace.default_memory_limit,
