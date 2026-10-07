//! The one attention order every surface shares: the sidebar list, "next
//! agent that needs me" and toast order. Agents that need the person come
//! first, then those working, then finished turns nobody has seen, then
//! idle ones, then agents whose state is unknown. Inside a group the most
//! recent status change comes first, and the pane key breaks ties so the
//! order is stable across revisions.

const data = @import("model");
const core = @import("telar-core");
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
pub fn group(status: core.AgentStatus) Group {
    return switch (status) {
        .blocked, .failed => .needs_input,
        .working => .working,
        .done => .ready_unseen,
        .ready => .idle,
        .unknown => .unknown,
    };
}

/// The three-way order behind `lessThan`.
///
/// ```zig
/// const first = if (attention.compare(a, b) == .lt) a else b;
/// ```
pub fn compare(left: *const data.Agent, right: *const data.Agent) std.math.Order {
    const by_group = std.math.order(@intFromEnum(group(left.status)), @intFromEnum(group(right.status)));
    if (by_group != .eq) {
        return by_group;
    }

    const by_age = std.math.order(left.status_age_s, right.status_age_s);
    if (by_age != .eq) {
        return by_age;
    }

    const by_pane = std.math.order(core.raw(left.key.pane_id), core.raw(right.key.pane_id));
    if (by_pane != .eq) {
        return by_pane;
    }

    return std.math.order(left.key.pane_generation, right.key.pane_generation);
}
