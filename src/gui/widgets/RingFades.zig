//! Bounded attention transitions owned by the chrome and keyed by attachment.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const RingFade = @import("RingFade.zig");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const RingFades = @This();

pub const duration_ns = 360 * std.time.ns_per_ms;

// One previous visible set plus one replacement set until end prunes it.
// SAFETY: insert writes each transition before increasing len; sampling and pruning use only that initialized prefix.
entries: [2 * core.max_panes_per_tab]RingFade = undefined,
len: usize = 0,
seen: [2 * core.max_panes_per_tab]bool = @splat(false),

/// Marks the new visible set without advancing animation state.
/// Example: `rings.begin();`
pub fn begin(self: *RingFades) void {
    self.seen = @splat(false);
}

/// Samples time and requests a wake even when no agent is working.
/// Example: `const opacity = rings.alpha(attachment, &clock);`
pub fn alpha(self: *RingFades, key: data.AgentKey, clock: *FrameClock) f32 {
    const index = self.find(key) orelse self.insert(.{
        .key = key,
        .transition = .{ .from = 0, .to = 1, .started_ns = clock.now_ns, .duration_ns = duration_ns },
    }) orelse return 1;
    self.seen[index] = true;
    return clock.sample(self.entries[index].transition);
}

/// Retires transitions which no visible widget sampled this frame.
/// Example: `rings.end();`
pub fn end(self: *RingFades) void {
    var kept: usize = 0;
    for (0..self.len) |index| {
        if (self.seen[index]) {
            self.entries[kept] = self.entries[index];
            kept += 1;
        }
    }

    self.len = kept;
}

fn find(self: *const RingFades, key: data.AgentKey) ?usize {
    for (self.entries[0..self.len], 0..) |entry, index| {
        if (std.meta.eql(entry.key, key)) {
            return index;
        }
    }

    return null;
}

fn insert(self: *RingFades, entry: RingFade) ?usize {
    if (self.len < self.entries.len) {
        const index = self.len;
        self.entries[index] = entry;
        self.len += 1;
        return index;
    }

    return null;
}
