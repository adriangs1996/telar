/// Host health sampled by the runtime, so the client reports the machine the
/// agents actually run on rather than the one showing the UI. Memory is in
/// tenths of a GiB so neither peer formats floating point. A host without a
/// battery reports `has_battery = false` and the client hides the segment.
const SystemMetrics = @This();

revision: u64,
cpu_percent: u8,
memory_used_decigib: u16,
has_battery: bool,
battery_percent: u8,

pub fn validateWire(message: SystemMetrics) !void {
    if (message.revision == 0) {
        return error.InvalidMetricsRevision;
    }
    if (message.cpu_percent > 100) {
        return error.InvalidMetricsValue;
    }
    if (message.has_battery and message.battery_percent > 100) {
        return error.InvalidMetricsValue;
    }
    if (!message.has_battery and message.battery_percent != 0) {
        return error.InvalidMetricsValue;
    }
}
