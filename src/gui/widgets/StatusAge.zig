const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const StatusAge = @This();

key: data.AgentKey,
status: core.AgentStatus,
provider: core.AgentProvider,
reported_s: u32,
age_ns: u64,
sampled_ns: u64,

pub fn init(agent: *const data.Agent, now_ns: u64) StatusAge {
    return .{
        .key = agent.key,
        .status = agent.status,
        .provider = agent.provider,
        .reported_s = agent.statusAgeSeconds(),
        .age_ns = @as(u64, agent.statusAgeSeconds()) * std.time.ns_per_s,
        .sampled_ns = now_ns,
    };
}

/// Keeps fractional progress across reports for the same status. A changed
/// status, provider or decreasing reported age starts a new interval.
/// Example: `age.observe(agent, now_ns);`
pub fn observe(self: *StatusAge, agent: *const data.Agent, now_ns: u64) void {
    var next = init(agent, now_ns);
    if (std.meta.eql(self.key, next.key) and self.status == next.status and
        self.provider == next.provider and next.reported_s >= self.reported_s)
    {
        next.age_ns = @max(next.age_ns, self.elapsed(now_ns));
    }

    self.* = next;
}

pub fn seconds(self: *const StatusAge, now_ns: u64) u32 {
    return @intCast(@min(std.math.maxInt(u32), self.elapsed(now_ns) / std.time.ns_per_s));
}

fn elapsed(self: *const StatusAge, now_ns: u64) u64 {
    return self.age_ns +| (now_ns -| self.sampled_ns);
}
