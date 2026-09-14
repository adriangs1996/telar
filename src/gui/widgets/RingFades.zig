//! Bounded attention transitions owned by the chrome and keyed by attachment.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const RingFade = @import("RingFade.zig");
const FrameClock = @import("../animation/FrameClock.zig");
const RingFades = @This();

pub const duration_ns = 360 * std.time.ns_per_ms;

// One previous visible set plus one replacement set until end prunes it.
entries: [2 * core.max_panes_per_tab]RingFade = undefined,
len: usize = 0,
seen: [2 * core.max_panes_per_tab]bool = @splat(false),

/// Marks the new visible set without advancing animation state.
/// Example: `rings.begin();`
pub fn begin(rings: *RingFades) void {
    rings.seen = @splat(false);
}

/// Samples time and requests a wake even when no agent is working.
/// Example: `const opacity = rings.alpha(attachment, &clock);`
pub fn alpha(rings: *RingFades, key: client.AgentKey, clock: *FrameClock) f32 {
    const index = rings.find(key) orelse rings.insert(.{
        .key = key,
        .transition = .{ .from = 0, .to = 1, .started_ns = clock.now_ns, .duration_ns = duration_ns },
    }) orelse return 1;
    rings.seen[index] = true;
    return clock.sample(rings.entries[index].transition);
}

/// Retires transitions which no visible widget sampled this frame.
/// Example: `rings.end();`
pub fn end(rings: *RingFades) void {
    var kept: usize = 0;
    for (0..rings.len) |index| {
        if (rings.seen[index]) {
            rings.entries[kept] = rings.entries[index];
            kept += 1;
        }
    }

    rings.len = kept;
}

fn find(rings: *const RingFades, key: client.AgentKey) ?usize {
    for (rings.entries[0..rings.len], 0..) |entry, index| {
        if (std.meta.eql(entry.key, key)) {
            return index;
        }
    }

    return null;
}

fn insert(rings: *RingFades, entry: RingFade) ?usize {
    if (rings.len < rings.entries.len) {
        const index = rings.len;
        rings.entries[index] = entry;
        rings.len += 1;
        return index;
    }

    return null;
}

test "attention transitions fold missed frames park and reset on reattachment" {
    var rings: RingFades = .{};
    var clock: FrameClock = .{};
    var key: client.AgentKey = .{ .pane_id = @enumFromInt(7), .pane_generation = 1 };
    clock.begin(0);
    rings.begin();
    try std.testing.expectEqual(@as(f32, 0), rings.alpha(key, &clock));
    try std.testing.expect(clock.deadline_ns != null);
    rings.end();
    clock.begin(duration_ns / 2);
    rings.begin();
    try std.testing.expectEqual(@as(f32, 0.5), rings.alpha(key, &clock));
    try std.testing.expectEqual(@as(f32, 0.5), rings.alpha(key, &clock));
    rings.end();
    clock.begin(4 * duration_ns);
    rings.begin();
    try std.testing.expectEqual(@as(f32, 1), rings.alpha(key, &clock));
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(clock.now_ns));
    rings.end();
    key.pane_generation += 1;
    rings.begin();
    try std.testing.expectEqual(@as(f32, 0), rings.alpha(key, &clock));
    rings.end();
    try std.testing.expectEqual(@as(usize, 1), rings.len);
    clock.begin(5 * duration_ns);
    rings.begin();
    rings.end();
    try std.testing.expectEqual(@as(usize, 0), rings.len);
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(clock.now_ns));
}
