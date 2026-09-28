const SystemMetrics = @This();

runtime_revision: u64,
cpu_percent: u8,
memory_used_decigib: u16,
battery_percent: ?u8,
/// Zero when the runtime could not read them.
cpu_count: u16 = 0,
memory_total_decigib: u16 = 0,
