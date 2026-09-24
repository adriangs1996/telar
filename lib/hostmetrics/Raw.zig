/// Raw counters one platform read produces. Cpu ticks are cumulative since
/// boot; the sampler turns consecutive reads into a percentage.
const Raw = @This();

busy_ticks: u64,
total_ticks: u64,
memory_used_bytes: u64,
battery_percent: ?u8,
