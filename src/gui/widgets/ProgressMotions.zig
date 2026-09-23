//! Bounded native progress state scoped to visible pane attachments.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Transition = @import("../animation/Transition.zig");
const FrameClock = @import("../animation/FrameClock.zig");
const ProgressMotions = @This();

// The previous visible set and its replacement coexist until end prunes it.
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

fn testPane() !data.Pane {
    return data.Pane.init(std.testing.allocator, .{
        .spec = .{
            .pane_id = @enumFromInt(1),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
            .size = .{ .cols = 1, .rows = 1 },
        },
        .attached = true,
    });
}

test "progress motion starts at the known percentage eases updates and parks" {
    var pane = try testPane();
    defer pane.deinit();
    pane.progress_state = .set;
    pane.progress_percent = 20;
    var motions: ProgressMotions = .{};
    var clock: FrameClock = .{};

    clock.begin(0);
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.2), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    motions.end();

    pane.progress_percent = 80;
    clock.begin(100 * std.time.ns_per_ms);
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.2), motions.fraction(&pane, &clock));
    try std.testing.expect(clock.deadline_ns != null);
    motions.end();

    clock.begin(220 * std.time.ns_per_ms);
    motions.begin();
    try std.testing.expectApproxEqAbs(@as(f32, 0.725), motions.fraction(&pane, &clock), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.725), motions.fraction(&pane, &clock), 0.00001);
    motions.end();

    clock.begin(340 * std.time.ns_per_ms);
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.8), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    motions.end();
}

test "progress retargets from its eased position and folds late frames" {
    var pane = try testPane();
    defer pane.deinit();
    pane.progress_state = .set;
    pane.progress_percent = 20;
    var motions: ProgressMotions = .{};
    var clock: FrameClock = .{};

    clock.begin(0);
    motions.begin();
    _ = motions.fraction(&pane, &clock);
    pane.progress_percent = 80;
    _ = motions.fraction(&pane, &clock);
    motions.end();

    clock.begin(120 * std.time.ns_per_ms);
    motions.begin();
    pane.progress_percent = 40;
    try std.testing.expectApproxEqAbs(@as(f32, 0.725), motions.fraction(&pane, &clock), 0.00001);
    motions.end();

    clock.begin(240 * std.time.ns_per_ms);
    motions.begin();
    try std.testing.expectApproxEqAbs(@as(f32, 0.440625), motions.fraction(&pane, &clock), 0.00001);
    motions.end();

    clock.begin(100 * std.time.ns_per_s);
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.4), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    motions.end();
}

test "paused errored and indeterminate progress never keep interpolation timers alive" {
    var pane = try testPane();
    defer pane.deinit();
    pane.progress_percent = 10;
    var motions: ProgressMotions = .{};
    var clock: FrameClock = .{};

    for ([_]core.PaneProgressState{ .pause, .@"error", .indeterminate }) |state| {
        pane.progress_state = .set;
        clock.begin(clock.now_ns + std.time.ns_per_s);
        motions.begin();
        _ = motions.fraction(&pane, &clock);
        pane.progress_percent = 90;
        _ = motions.fraction(&pane, &clock);
        motions.end();

        pane.progress_state = state;
        pane.progress_percent = 40;
        clock.begin(clock.now_ns + std.time.ns_per_ms);
        motions.begin();
        try std.testing.expectEqual(@as(f32, 0.4), motions.fraction(&pane, &clock));
        try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
        motions.end();

        pane.progress_percent = null;
        clock.begin(clock.now_ns + std.time.ns_per_ms);
        motions.begin();
        try std.testing.expectEqual(@as(f32, 0), motions.fraction(&pane, &clock));
        try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
        motions.end();
    }

    pane.progress_state = .set;
    pane.progress_percent = 70;
    clock.begin(clock.now_ns + std.time.ns_per_ms);
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.7), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    motions.end();
}

test "unknown progress shows zero and the first known value without an invented transition" {
    var pane = try testPane();
    defer pane.deinit();
    pane.progress_state = .set;
    var motions: ProgressMotions = .{};
    var clock: FrameClock = .{};
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0), motions.fraction(&pane, &clock));
    pane.progress_percent = 75;
    try std.testing.expectEqual(@as(f32, 0.75), motions.fraction(&pane, &clock));
    pane.progress_percent = null;
    try std.testing.expectEqual(@as(f32, 0), motions.fraction(&pane, &clock));
    pane.progress_percent = 255;
    try std.testing.expectEqual(@as(f32, 1), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    motions.end();
}

test "progress state is retired on hide remove and attachment replacement" {
    var pane = try testPane();
    defer pane.deinit();
    pane.progress_state = .set;
    pane.progress_percent = 20;
    var motions: ProgressMotions = .{};
    var clock: FrameClock = .{};
    motions.begin();
    _ = motions.fraction(&pane, &clock);
    motions.end();

    pane.attachment_generation += 1;
    pane.progress_percent = 80;
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.8), motions.fraction(&pane, &clock));
    motions.end();
    try std.testing.expectEqual(@as(usize, 1), motions.len);
    try std.testing.expectEqual(pane.attachment_generation, motions.entries[0].key.pane_generation);

    pane.progress_state = .remove;
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(usize, 0), motions.len);
    pane.progress_state = .set;
    pane.progress_percent = 50;
    try std.testing.expectEqual(@as(f32, 0.5), motions.fraction(&pane, &clock));
    motions.end();

    motions.begin();
    motions.end();
    try std.testing.expectEqual(@as(usize, 0), motions.len);
    pane.progress_percent = 10;
    motions.begin();
    try std.testing.expectEqual(@as(f32, 0.1), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    motions.end();
}

test "progress storage stays bounded across disjoint visible sets and degrades to reported values" {
    var pane = try testPane();
    defer pane.deinit();
    pane.progress_state = .set;
    pane.progress_percent = 25;
    var motions: ProgressMotions = .{};
    var clock: FrameClock = .{};
    motions.begin();
    for (0..core.max_panes_per_tab) |index| {
        pane.id = @enumFromInt(index + 1);
        _ = motions.fraction(&pane, &clock);
    }

    motions.end();
    motions.begin();
    for (0..core.max_panes_per_tab) |index| {
        pane.id = @enumFromInt(core.max_panes_per_tab + index + 1);
        _ = motions.fraction(&pane, &clock);
    }

    try std.testing.expectEqual(motions.entries.len, motions.len);
    pane.id = @enumFromInt(2 * core.max_panes_per_tab + 1);
    pane.progress_percent = 90;
    try std.testing.expectEqual(@as(f32, 0.9), motions.fraction(&pane, &clock));
    try std.testing.expectEqual(motions.entries.len, motions.len);
    motions.end();
    try std.testing.expectEqual(@as(usize, core.max_panes_per_tab), motions.len);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
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
