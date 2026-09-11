/// The first read has no predecessor, so it reports zero instead of a
/// since-boot average that would spike the bar on startup.
const CpuTicks = @This();

busy: u64,
total: u64,
