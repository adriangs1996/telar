const Timing = @This();

count: u64 = 0,
total_ns: u64 = 0,
max_ns: u64 = 0,

pub fn observe(self: *Timing, elapsed_ns: u64) void {
    self.count += 1;
    self.total_ns +|= elapsed_ns;
    self.max_ns = @max(self.max_ns, elapsed_ns);
}

pub fn average(self: Timing) u64 {
    return if (self.count == 0) 0 else self.total_ns / self.count;
}

/// Folds samples collected elsewhere into this timing, so a per-object
/// timing drained on a boundary can feed one process-wide aggregate.
///
/// ```zig
/// metrics.graphics_freeze.merge(counts.freeze);
/// ```
pub fn merge(self: *Timing, other: Timing) void {
    self.count +|= other.count;
    self.total_ns +|= other.total_ns;
    self.max_ns = @max(self.max_ns, other.max_ns);
}
