//! Bounded position transitions, keyed by tab identity rather than strip index.
const std = @import("std");
const core = @import("telar-core");
const animate = @import("animate");
const Clock = animate.FrameClock;
const Slot = @import("TabSlot.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Transition = animate.Transition;
const TabMotions = @This();

// SAFETY: place initializes a motion before increasing len; begin, lookup and finish visit only entries below len.
entries: [core.max_tabs_per_workspace]Motion = undefined,
len: usize = 0,
workspace: ?core.WorkspaceLocation = null,

/// Example: `motions.begin(tabs.workspace);`
pub fn begin(self: *TabMotions, workspace: ?core.WorkspaceLocation) void {
    if (!std.meta.eql(self.workspace, workspace)) {
        self.len = 0;
        self.workspace = workspace;
    }

    for (self.entries[0..self.len]) |*entry| {
        entry.seen = false;
    }
}

/// Retargets from the currently sampled position, including mid-animation.
/// Example: `const visible = motions.place(.{ .id = tab_id, .bounds = slot }, clock);`
pub fn place(self: *TabMotions, slot: Slot, clock: *Clock) Rect {
    for (self.entries[0..self.len]) |*entry| {
        if (entry.id != slot.id) {
            continue;
        }

        entry.seen = true;
        if (slot.immediate) {
            entry.from = slot.bounds;
            entry.to = slot.bounds;
            entry.transition.duration_ns = 0;
            return slot.bounds;
        }
        if (!std.meta.eql(entry.to, slot.bounds)) {
            entry.from = entry.value(clock.now_ns);
            entry.to = slot.bounds;
            entry.transition = .{ .from = 0, .to = 1, .started_ns = clock.now_ns, .duration_ns = 180 * std.time.ns_per_ms };
        }

        _ = clock.sample(entry.transition);
        return entry.value(clock.now_ns);
    }

    if (self.len < self.entries.len) {
        self.entries[self.len] = .{ .id = slot.id, .from = slot.bounds, .to = slot.bounds, .transition = .{ .from = 1, .to = 1, .started_ns = clock.now_ns, .duration_ns = 0 } };
        self.len += 1;
    }

    return slot.bounds;
}

/// Example: `motions.finish();`
pub fn finish(self: *TabMotions) void {
    var kept: usize = 0;
    for (self.entries[0..self.len]) |entry| {
        if (entry.seen) {
            self.entries[kept] = entry;
            kept += 1;
        }
    }

    self.len = kept;
}

const Motion = struct {
    id: core.TabId,
    from: Rect,
    to: Rect,
    transition: Transition,
    seen: bool = true,

    /// Cubic ease-out keeps a quick response and a soft landing.
    /// Example: `const bounds = motion.value(clock.now_ns);`
    pub fn value(self: Motion, now_ns: u64) Rect {
        const t = self.transition.value(now_ns);
        const eased = 1 - (1 - t) * (1 - t) * (1 - t);
        return .{
            .x = self.from.x + (self.to.x - self.from.x) * eased,
            .y = self.from.y + (self.to.y - self.from.y) * eased,
            .width = self.from.width + (self.to.width - self.from.width) * eased,
            .height = self.from.height + (self.to.height - self.from.height) * eased,
        };
    }
};
