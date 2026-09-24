//! Host health without allocation: cpu percent from tick deltas, memory in
//! use and battery, read from mach counters on macOS and procfs and sysfs on
//! Linux.

pub const Sampler = @import("Sampler.zig");
pub const SystemMetricsSample = @import("SystemMetricsSample.zig");
pub const system_metrics = @import("system_metrics.zig");

test {
    _ = @import("Raw.zig");
    _ = @import("Sampler.zig");
    _ = @import("SystemMetricsSample.zig");
    _ = @import("Values.zig");
    _ = @import("darwin.zig");
    _ = @import("system_metrics.zig");
}
