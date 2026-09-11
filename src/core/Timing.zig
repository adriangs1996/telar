const Timing = @This();

count: u64 = 0,
total_ns: u64 = 0,
max_ns: u64 = 0,

pub fn observe(timing: *Timing, elapsed_ns: u64) void {
    timing.count += 1;
    timing.total_ns +|= elapsed_ns;
    timing.max_ns = @max(timing.max_ns, elapsed_ns);
}

pub fn average(timing: Timing) u64 {
    return if (timing.count == 0) 0 else timing.total_ns / timing.count;
}

/// Folds samples collected elsewhere into this timing, so a per-object
/// timing drained on a boundary can feed one process-wide aggregate.
///
/// ```zig
/// metrics.graphics_freeze.merge(counts.freeze);
/// ```
pub fn merge(timing: *Timing, other: Timing) void {
    timing.count +|= other.count;
    timing.total_ns +|= other.total_ns;
    timing.max_ns = @max(timing.max_ns, other.max_ns);
}
