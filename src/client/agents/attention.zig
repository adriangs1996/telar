//! The one attention order every surface shares: the sidebar list, "next
//! agent that needs me" and toast order. Agents that need the person come
//! first, then those working, then finished turns nobody has seen, then
//! idle ones, then agents whose state is unknown. Inside a group the most
//! recent status change comes first, and the pane key breaks ties so the
//! order is stable across revisions.

const Agent = @import("Agent.zig");
const AgentInput = @import("AgentInput.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const raw_module = @import("telar-core").raw;
const std = @import("std");

/// Attention groups from most to least urgent.
pub const Group = enum(u8) {
    needs_input = 0,
    working = 1,
    ready_unseen = 2,
    idle = 3,
    unknown = 4,
};

/// The attention group of one status.
///
/// ```zig
/// if (group(agent.status) == .needs_input) count += 1;
/// ```
pub fn group(status: AgentStatusType) Group {
    return switch (status) {
        .blocked, .failed => .needs_input,
        .working => .working,
        .done => .ready_unseen,
        .ready => .idle,
        .unknown => .unknown,
    };
}

/// Orders two agents for presentation: attention group, then the most
/// recent status change first, then pane id and generation. Pure and
/// allocation-free, so `std.sort` can take it directly.
///
/// ```zig
/// std.sort.pdq(*const Agent, agents, {}, attention.lessThan);
/// ```
pub fn lessThan(_: void, left: *const Agent, right: *const Agent) bool {
    return compare(left, right) == .lt;
}

/// The three-way order behind `lessThan`.
///
/// ```zig
/// const first = if (attention.compare(a, b) == .lt) a else b;
/// ```
pub fn compare(left: *const Agent, right: *const Agent) std.math.Order {
    const by_group = std.math.order(@intFromEnum(group(left.status)), @intFromEnum(group(right.status)));
    if (by_group != .eq) {
        return by_group;
    }

    const by_age = std.math.order(left.status_age_s, right.status_age_s);
    if (by_age != .eq) {
        return by_age;
    }

    const by_pane = std.math.order(raw_module(left.key.pane_id), raw_module(right.key.pane_id));
    if (by_pane != .eq) {
        return by_pane;
    }

    return std.math.order(left.key.pane_generation, right.key.pane_generation);
}

fn testingAgent(pane: u64, status: AgentStatusType, age: u32) !Agent {
    return try Agent.init(testingInput(pane, status, age));
}

fn testingInput(pane: u64, status: AgentStatusType, age: u32) AgentInput {
    return .{
        .key = .{ .pane_id = @enumFromInt(pane), .pane_generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .claude,
        .status = status,
        .status_age_s = age,
    };
}

test "attention groups order blocked and failed before working, done, ready and unknown" {
    const blocked = try testingAgent(1, .blocked, 500);
    const failed = try testingAgent(2, .failed, 500);
    const working = try testingAgent(3, .working, 1);
    const done = try testingAgent(4, .done, 1);
    const ready = try testingAgent(5, .ready, 1);
    const unknown = try testingAgent(6, .unknown, 1);

    try std.testing.expectEqual(std.math.Order.lt, compare(&blocked, &working));
    try std.testing.expectEqual(std.math.Order.lt, compare(&failed, &working));
    try std.testing.expectEqual(std.math.Order.lt, compare(&working, &done));
    try std.testing.expectEqual(std.math.Order.lt, compare(&done, &ready));
    try std.testing.expectEqual(std.math.Order.lt, compare(&ready, &unknown));
    try std.testing.expectEqual(std.math.Order.gt, compare(&unknown, &blocked));
    try std.testing.expectEqual(Group.needs_input, group(.failed));
}

test "inside a group the most recent status change comes first" {
    const older = try testingAgent(1, .working, 120);
    const newer = try testingAgent(2, .working, 3);

    try std.testing.expectEqual(std.math.Order.lt, compare(&newer, &older));
    try std.testing.expect(lessThan({}, &newer, &older));
    try std.testing.expect(!lessThan({}, &older, &newer));
}

test "equal groups and ages fall back to the pane key so the order is stable" {
    const low = try testingAgent(2, .ready, 7);
    const high = try testingAgent(9, .ready, 7);
    var later = try testingAgent(2, .ready, 7);
    later.key.pane_generation = 2;

    try std.testing.expectEqual(std.math.Order.lt, compare(&low, &high));
    try std.testing.expectEqual(std.math.Order.lt, compare(&low, &later));
    try std.testing.expectEqual(std.math.Order.eq, compare(&low, &low));
}

test "sorting a mixed list yields the sidebar order" {
    var agents = [_]Agent{
        try testingAgent(1, .ready, 10),
        try testingAgent(2, .working, 30),
        try testingAgent(3, .blocked, 90),
        try testingAgent(4, .done, 5),
        try testingAgent(5, .working, 2),
        try testingAgent(6, .unknown, 0),
        try testingAgent(7, .failed, 20),
    };
    var order: [agents.len]*const Agent = undefined;
    for (&agents, 0..) |*agent, index| {
        order[index] = agent;
    }

    std.sort.pdq(*const Agent, &order, {}, lessThan);

    const expected = [_]u64{ 7, 3, 5, 2, 4, 1, 6 };
    for (expected, order) |pane, agent| {
        try std.testing.expectEqual(pane, raw_module(agent.key.pane_id));
    }
}
