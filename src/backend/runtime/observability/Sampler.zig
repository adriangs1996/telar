const Values = @import("Values.zig");
const system_metrics = @import("system_metrics.zig");
const Raw = @import("Raw.zig");
const std = @import("std");
const Sampler = @This();

revision: u64 = 1,
latest: ?Values = null,
previous_busy: u64 = 0,
previous_total: u64 = 0,

/// Reads the current host counters and retains the previous projection when
/// the platform cannot provide a complete sample. The revision changes
/// only when the values visible to clients change.
///
/// ```zig
/// sampler.sample();
/// ```
pub fn sample(sampler: *Sampler) void {
    const raw = system_metrics.readRaw() orelse return;
    sampler.apply(raw);
}

pub fn apply(sampler: *Sampler, raw: Raw) void {
    const cpu = system_metrics.cpuPercent(
        .{ .busy = sampler.previous_busy, .total = sampler.previous_total },
        .{ .busy = raw.busy_ticks, .total = raw.total_ticks },
    );
    sampler.previous_busy = raw.busy_ticks;
    sampler.previous_total = raw.total_ticks;
    const next: Values = .{
        .cpu_percent = cpu,
        .memory_used_decigib = system_metrics.decigib(raw.memory_used_bytes),
        .battery_percent = raw.battery_percent,
    };
    if (sampler.latest) |current| {
        if (std.meta.eql(current, next)) {
            return;
        }
    }
    sampler.latest = next;
    sampler.revision +%= 1;
    if (sampler.revision == 0) {
        sampler.revision = 1;
    }
}
