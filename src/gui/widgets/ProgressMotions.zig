//! Bounded native progress state scoped to visible pane attachments.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const animate = @import("animate");
const Transition = animate.Transition;
const FrameClock = animate.FrameClock;
const ProgressMotions = @This();

// The previous visible set and its replacement coexist until end prunes it.
// SAFETY: insert writes each motion before increasing len; lookup, sampling and pruning use only initialized entries.
entries: [2 * core.max_panes_per_tab]ProgressMotion = undefined,
len: usize = 0,
seen: [2 * core.max_panes_per_tab]bool = @splat(false),

/// Marks a new visible set without advancing its animations.
/// Example: `motions.begin();`
pub fn begin(self: *ProgressMotions) void {
    self.seen = @splat(false);
}

/// Samples one pane without retaining model pointers or scheduling idle frames.
/// Example: `const filled = motions.fraction(pane, &clock);`
pub fn fraction(self: *ProgressMotions, pane: *const data.Pane, clock: *FrameClock) f32 {
    const key: data.AgentKey = .{
        .pane_id = pane.id,
        .pane_generation = pane.attachment_generation,
    };
    if (pane.progress_state == .remove) {
        self.remove(key);
        return 0;
    }

    const index = self.find(key) orelse self.insert(.{ .key = key }) orelse return ProgressMotion.reported(pane);
    self.seen[index] = true;
    return self.entries[index].sample(pane, clock);
}

/// Retires hidden, removed and replaced attachments after the frame.
/// Example: `motions.end();`
pub fn end(self: *ProgressMotions) void {
    var kept: usize = 0;
    for (0..self.len) |index| {
        if (self.seen[index]) {
            self.entries[kept] = self.entries[index];
            kept += 1;
        }
    }

    self.len = kept;
}

fn find(self: *const ProgressMotions, key: data.AgentKey) ?usize {
    for (self.entries[0..self.len], 0..) |entry, index| {
        if (std.meta.eql(entry.key, key)) {
            return index;
        }
    }

    return null;
}

fn insert(self: *ProgressMotions, entry: ProgressMotion) ?usize {
    if (self.len == self.entries.len) {
        return null;
    }

    const index = self.len;
    self.entries[index] = entry;
    self.len += 1;
    return index;
}

fn remove(self: *ProgressMotions, key: data.AgentKey) void {
    const index = self.find(key) orelse return;
    self.len -= 1;
    self.entries[index] = self.entries[self.len];
    self.seen[index] = self.seen[self.len];
}

/// One attachment's disposable progress interpolation; never borrows its pane.
const ProgressMotion = struct {
    pub const duration_ns = 240 * std.time.ns_per_ms;

    key: data.AgentKey,
    from: f32 = 0,
    to: f32 = 0,
    known: bool = false,
    transition: Transition = .{ .from = 0, .to = 1, .started_ns = 0, .duration_ns = 0 },

    /// Retargets from the visible eased value, folding any frames that were missed.
    /// Example: `const fraction = motion.sample(pane, &clock);`
    pub fn sample(self: *ProgressMotion, pane: *const data.Pane, clock: *FrameClock) f32 {
        const target = reported(pane);
        if (pane.progress_state != .set or pane.progress_percent == null or !self.known) {
            self.from = target;
            self.to = target;
            self.known = pane.progress_percent != null and pane.progress_state != .indeterminate;
            self.transition.duration_ns = 0;
            return target;
        }

        if (target != self.to) {
            self.from = self.value(self.transition.value(clock.now_ns));
            self.to = target;
            self.transition.started_ns = clock.now_ns;
            self.transition.duration_ns = if (self.from == target) 0 else duration_ns;
        }

        return self.value(clock.sample(self.transition));
    }

    /// Unknown percentages have no determinate fill; bounds remain valid for all u8 values.
    /// Example: `const fraction = ProgressMotion.reported(pane);`
    pub fn reported(pane: *const data.Pane) f32 {
        return @as(f32, @floatFromInt(@min(pane.progress_percent orelse 0, 100))) / 100;
    }

    fn value(self: ProgressMotion, phase: f32) f32 {
        if (phase >= 1) {
            return self.to;
        }

        const remaining = 1 - phase;
        const eased = 1 - remaining * remaining * remaining;
        return std.math.clamp(self.from + (self.to - self.from) * eased, 0, 1);
    }
};
