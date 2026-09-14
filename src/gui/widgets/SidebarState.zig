//! Disposable scroll bounds and attention order, independent of frame widgets.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const SnapshotMark = @import("SnapshotMark.zig");
const SidebarState = @This();

scroll: u16 = 0,
maximum_scroll: u16 = 0,
/// One wheel step in device pixels: the pitch of the last drawn card.
step: u16 = 0,
order: [core.max_agent_snapshot_entries]u8 = undefined,
order_len: u8 = 0,
ordered: SnapshotMark = .{},

/// Sorts only when the snapshot identity changes, retaining indices rather
/// than borrowed agents. Example: `state.observe(projection.agents);`
pub fn observe(state: *SidebarState, snapshot: *const client.AgentSnapshot) void {
    const mark = SnapshotMark.of(snapshot);
    if (state.ordered.eql(mark)) {
        return;
    }

    const agents = snapshot.slice();
    state.order_len = @intCast(@min(agents.len, state.order.len));
    for (state.order[0..state.order_len], 0..) |*slot, index| {
        slot.* = @intCast(index);
    }

    std.sort.pdq(u8, state.order[0..state.order_len], agents, indexLessThan);
    state.ordered = mark;
}

/// Applies the current list geometry within the bounded pixel scroll range.
/// Example: `state.setScrollBounds(geometry.pitch(), total - list.height);`
pub fn setScrollBounds(state: *SidebarState, step: f32, maximum: f32) void {
    state.step = @intFromFloat(@min(65535, step));
    state.maximum_scroll = @intFromFloat(@min(65535, @max(0, maximum)));
    state.scroll = @min(state.scroll, state.maximum_scroll);
}

/// An unavailable viewport keeps its offset until layout can constrain it.
/// Example: `state.hide();`
pub fn hide(state: *SidebarState) void {
    state.maximum_scroll = 0;
}

/// Scrolls by one card without changing the model.
/// Example: `if (state.wheel(.scroll_down)) chrome.invalidate();`
pub fn wheel(state: *SidebarState, kind: client.Mouse.Kind) bool {
    const next = switch (kind) {
        .scroll_up => state.scroll -| state.step,
        .scroll_down => @min(state.scroll +| state.step, state.maximum_scroll),
        else => state.scroll,
    };
    if (next == state.scroll) {
        return false;
    }

    state.scroll = next;
    return true;
}

/// Applies precise vertical movement within the last drawn scroll bounds.
/// Example: `if (state.scrollBy(delta_pixels)) chrome.invalidate();`
pub fn scrollBy(state: *SidebarState, delta: f64) bool {
    const next: u16 = @intFromFloat(@max(0, @min(@as(f64, @floatFromInt(state.maximum_scroll)), @as(f64, @floatFromInt(state.scroll)) + delta)));
    if (next == state.scroll) {
        return false;
    }

    state.scroll = next;
    return true;
}

/// The attention order of the last observed snapshot, as replica indices.
/// Example: `for (state.ordering()) |index| { ... }`
pub fn ordering(state: *const SidebarState) []const u8 {
    return state.order[0..state.order_len];
}

fn indexLessThan(agents: []const client.Agent, left: u8, right: u8) bool {
    return client.agent_attention.lessThan({}, &agents[left], &agents[right]);
}
