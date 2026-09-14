//! Fade state of the attention rings, owned by the chrome and keyed by pane.
//! A ring becomes fully visible over `steps_to_full` animation frames, read
//! from the model's `sidebar_animation_frame`; when that counter is not
//! ticking there is nothing to animate against and the ring shows at once.
//! Bounded by the panes of one tab and pruned on every paint.
const core = @import("telar-core");
const RingFade = @import("RingFade.zig");
const RingMotion = @import("RingMotion.zig");
const RingFades = @This();

pub const steps_to_full: u8 = 3;

entries: [core.max_panes_per_tab]RingFade = undefined,
len: usize = 0,
last_frame: u8 = 0,
seen: [core.max_panes_per_tab]bool = @splat(false),

/// Starts a paint: remembers whether the frame counter moved since the last
/// one, so every ring advances by the same amount.
/// Example: `const advanced = rings.begin(projection.sidebar_animation_frame);`
pub fn begin(rings: *RingFades, frame: u8) bool {
    const advanced = frame != rings.last_frame;
    rings.last_frame = frame;
    rings.seen = @splat(false);
    return advanced;
}

/// The opacity of `pane_id`'s ring for this paint; `advanced` moves every
/// ring one step, `animated` false snaps it to full because no counter runs.
/// Example: `const alpha = rings.alpha(view.pane_id, .{ .advanced = advanced, .animated = working });`
pub fn alpha(rings: *RingFades, pane_id: core.PaneId, motion: RingMotion) f32 {
    const index = rings.find(pane_id) orelse rings.insert(pane_id);
    rings.seen[index] = true;
    var entry = &rings.entries[index];
    if (!motion.animated) {
        entry.steps = steps_to_full;
    } else if (motion.advanced and entry.steps < steps_to_full) {
        entry.steps += 1;
    }

    return @as(f32, @floatFromInt(entry.steps)) / @as(f32, steps_to_full);
}

/// Ends a paint by forgetting rings that were not drawn, so a pane whose
/// attention returns fades in again.
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

fn find(rings: *const RingFades, pane_id: core.PaneId) ?usize {
    for (rings.entries[0..rings.len], 0..) |entry, index| {
        if (entry.pane_id == pane_id) {
            return index;
        }
    }

    return null;
}

fn insert(rings: *RingFades, pane_id: core.PaneId) usize {
    if (rings.len == rings.entries.len) {
        rings.len -= 1;
    }

    rings.entries[rings.len] = .{ .pane_id = pane_id, .steps = 0 };
    rings.len += 1;
    return rings.len - 1;
}

test "rings fade in by animation frames and snap when nothing animates" {
    const std = @import("std");
    var rings: RingFades = .{};
    const pane: core.PaneId = @enumFromInt(7);
    var advanced = rings.begin(1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), rings.alpha(pane, .{ .advanced = advanced, .animated = true }), 0.001);
    rings.end();
    advanced = rings.begin(1);
    try std.testing.expect(!advanced);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), rings.alpha(pane, .{ .advanced = advanced, .animated = true }), 0.001);
    rings.end();
    advanced = rings.begin(2);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), rings.alpha(pane, .{ .advanced = advanced, .animated = true }), 0.001);
    rings.end();
    advanced = rings.begin(3);
    try std.testing.expectEqual(@as(f32, 1), rings.alpha(pane, .{ .advanced = advanced, .animated = true }));
    rings.end();
    _ = rings.begin(4);
    rings.end();
    try std.testing.expectEqual(@as(usize, 0), rings.len);
    advanced = rings.begin(5);
    try std.testing.expectEqual(@as(f32, 1), rings.alpha(pane, .{ .advanced = advanced, .animated = false }));
    rings.end();
}
