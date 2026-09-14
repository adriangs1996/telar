//! Client-local status clocks shared by native cards and pane headers.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const SnapshotMark = @import("SnapshotMark.zig");
const StatusAge = @import("StatusAge.zig");
const AgentAges = @This();

entries: [core.max_agent_snapshot_entries]StatusAge = undefined,
len: u8 = 0,
mark: SnapshotMark = .{},
now_ns: u64 = 0,

/// Reconciles clocks only on snapshot changes; ordinary paints advance one
/// monotonic timestamp. Storage is bounded and never borrows the model.
/// Example: `ages.observe(projection.agents, now_ns);`
pub fn observe(ages: *AgentAges, snapshot: *const client.AgentSnapshot, now_ns: u64) void {
    ages.now_ns = @max(ages.now_ns, now_ns);
    const mark = SnapshotMark.of(snapshot);
    if (ages.mark.eql(mark)) {
        return;
    }

    var replacement: [core.max_agent_snapshot_entries]StatusAge = undefined;
    for (snapshot.slice(), 0..) |*agent, index| {
        replacement[index] = if (ages.mark.source == mark.source)
            if (ages.find(agent.key)) |previous| previous.* else .init(agent, ages.now_ns)
        else
            .init(agent, ages.now_ns);
        replacement[index].observe(agent, ages.now_ns);
    }

    ages.len = snapshot.count;
    @memcpy(ages.entries[0..ages.len], replacement[0..ages.len]);
    ages.mark = mark;
}

/// Reads the same elapsed age for every occurrence of an agent in a frame.
/// Example: `const seconds = ages.seconds(agent);`
pub fn seconds(ages: *const AgentAges, agent: *const client.Agent) u32 {
    const age = ages.find(agent.key) orelse return agent.statusAgeSeconds();
    return age.seconds(ages.now_ns);
}

/// Uses snapshot order for constant-time reads while painting the agent list.
/// Example: `const seconds = ages.secondsAt(index);`
pub fn secondsAt(ages: *const AgentAges, index: usize) u32 {
    return ages.entries[0..ages.len][index].seconds(ages.now_ns);
}

fn find(ages: *const AgentAges, key: client.AgentKey) ?*const StatusAge {
    for (ages.entries[0..ages.len]) |*age| {
        if (std.meta.eql(age.key, key)) {
            return age;
        }
    }

    return null;
}

test "status clocks keep subsecond progress through frequent snapshots and reordering" {
    var snapshot: client.AgentSnapshot = .{};
    var ages: AgentAges = .{};
    const first: client.AgentInput = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 }, .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) }, .pane_index = 1, .provider = .codex, .status = .working, .status_age_s = 5 };
    var second = first;
    second.key.pane_id = @enumFromInt(2);
    second.status_age_s = 20;
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{ first, second } });
    ages.observe(&snapshot, 100_900 * std.time.ns_per_ms);
    ages.observe(&snapshot, 101_100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 5), ages.seconds(snapshot.find(first.key).?));

    for (2..12) |revision| {
        _ = try snapshot.replace(.{ .revision = revision, .agents = &.{ second, first } });
        ages.observe(&snapshot, (100_900 + revision * 100) * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(u32, 6), ages.seconds(snapshot.find(first.key).?));
    try std.testing.expectEqual(@as(u32, 21), ages.seconds(snapshot.find(second.key).?));
    ages.observe(&snapshot, 102_900 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 7), ages.seconds(snapshot.find(first.key).?));
}

test "status clocks reset for new intervals generations removals and replicas" {
    var snapshot: client.AgentSnapshot = .{};
    var ages: AgentAges = .{};
    var input: client.AgentInput = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 }, .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) }, .pane_index = 1, .provider = .codex, .status = .working, .status_age_s = 5 };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{input} });
    ages.observe(&snapshot, 100 * std.time.ns_per_s);
    input.status = .blocked;
    input.status_age_s = 0;
    _ = try snapshot.replace(.{ .revision = 2, .agents = &.{input} });
    ages.observe(&snapshot, 105 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 0), ages.seconds(&snapshot.slice()[0]));

    input.status_age_s = 10;
    _ = try snapshot.replace(.{ .revision = 3, .agents = &.{input} });
    ages.observe(&snapshot, 106 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 10), ages.seconds(&snapshot.slice()[0]));
    input.status_age_s = 1;
    _ = try snapshot.replace(.{ .revision = 4, .agents = &.{input} });
    ages.observe(&snapshot, 107 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), ages.seconds(&snapshot.slice()[0]));

    input.key.pane_generation += 1;
    _ = try snapshot.replace(.{ .revision = 5, .agents = &.{input} });
    ages.observe(&snapshot, 110 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), ages.seconds(&snapshot.slice()[0]));
    _ = try snapshot.replace(.{ .revision = 6, .agents = &.{} });
    ages.observe(&snapshot, 111 * std.time.ns_per_s);
    _ = try snapshot.replace(.{ .revision = 7, .agents = &.{input} });
    ages.observe(&snapshot, 112 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), ages.seconds(&snapshot.slice()[0]));

    var other = snapshot;
    ages.observe(&other, 115 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), ages.seconds(&other.slice()[0]));
    ages.observe(&other, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u32), ages.seconds(&other.slice()[0]));
}
