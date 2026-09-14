const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const StatusAge = @This();

key: client.AgentKey,
status: core.AgentStatus,
provider: core.AgentProvider,
reported_s: u32,
age_ns: u64,
sampled_ns: u64,

pub fn init(agent: *const client.Agent, now_ns: u64) StatusAge {
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
pub fn observe(age: *StatusAge, agent: *const client.Agent, now_ns: u64) void {
    var next = init(agent, now_ns);
    if (std.meta.eql(age.key, next.key) and age.status == next.status and
        age.provider == next.provider and next.reported_s >= age.reported_s)
    {
        next.age_ns = @max(next.age_ns, age.elapsed(now_ns));
    }

    age.* = next;
}

pub fn seconds(age: *const StatusAge, now_ns: u64) u32 {
    return @intCast(@min(std.math.maxInt(u32), age.elapsed(now_ns) / std.time.ns_per_s));
}

fn elapsed(age: *const StatusAge, now_ns: u64) u64 {
    return age.age_ns +| (now_ns -| age.sampled_ns);
}
