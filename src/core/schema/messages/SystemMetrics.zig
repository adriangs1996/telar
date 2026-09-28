/// Host health sampled by the runtime, so the client reports the machine the
/// agents actually run on rather than the one showing the UI. Memory is in
/// tenths of a GiB so neither peer formats floating point. A host without a
/// battery reports `has_battery = false` and the client hides the segment.
/// The CPU count and total memory size the host for placement; zero means
/// the runtime could not read them.
const SystemMetrics = @This();

revision: u64,
cpu_percent: u8,
memory_used_decigib: u16,
has_battery: bool,
battery_percent: u8,
cpu_count: u16,
memory_total_decigib: u16,

pub fn validateWire(self: SystemMetrics) !void {
    if (self.revision == 0) {
        return error.InvalidMetricsRevision;
    }
    if (self.cpu_percent > 100) {
        return error.InvalidMetricsValue;
    }
    if (self.has_battery and self.battery_percent > 100) {
        return error.InvalidMetricsValue;
    }
    if (!self.has_battery and self.battery_percent != 0) {
        return error.InvalidMetricsValue;
    }
}
