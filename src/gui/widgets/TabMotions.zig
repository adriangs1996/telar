//! Bounded position transitions, keyed by tab identity rather than strip index.
const std = @import("std");
const core = @import("telar-core");
const Clock = @import("../animation/FrameClock.zig");
const Motion = @import("TabMotion.zig");
const Slot = @import("TabSlot.zig");
const Rect = @import("../render/Rect.zig");
const TabMotions = @This();

entries: [core.max_tabs_per_workspace]Motion = undefined,
len: usize = 0,
workspace: ?core.WorkspaceLocation = null,

/// Example: `motions.begin(tabs.workspace);`
pub fn begin(motions: *TabMotions, workspace: ?core.WorkspaceLocation) void {
    if (!std.meta.eql(motions.workspace, workspace)) {
        motions.len = 0;
        motions.workspace = workspace;
    }

    for (motions.entries[0..motions.len]) |*entry| {
        entry.seen = false;
    }
}

/// Retargets from the currently sampled position, including mid-animation.
/// Example: `const visible = motions.place(.{ .id = tab_id, .bounds = slot }, clock);`
pub fn place(motions: *TabMotions, slot: Slot, clock: *Clock) Rect {
    for (motions.entries[0..motions.len]) |*entry| {
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

    if (motions.len < motions.entries.len) {
        motions.entries[motions.len] = .{ .id = slot.id, .from = slot.bounds, .to = slot.bounds, .transition = .{ .from = 1, .to = 1, .started_ns = clock.now_ns, .duration_ns = 0 } };
        motions.len += 1;
    }

    return slot.bounds;
}

/// Example: `motions.finish();`
pub fn finish(motions: *TabMotions) void {
    var kept: usize = 0;
    for (motions.entries[0..motions.len]) |entry| {
        if (entry.seen) {
            motions.entries[kept] = entry;
            kept += 1;
        }
    }

    motions.len = kept;
}

test "tab reflow eases retargets continuously and parks its shared clock" {
    var motions: TabMotions = .{};
    var clock: Clock = .{};
    const slot: Slot = .{ .id = @enumFromInt(1), .bounds = .{ .x = 0, .y = 7, .width = 100, .height = 35 } };
    _ = motions.place(slot, &clock);
    var moved = slot;
    moved.bounds.x = 300;
    try std.testing.expectEqual(@as(f32, 0), motions.place(moved, &clock).x);
    try std.testing.expect(clock.deadline_ns != null);
    clock.begin(90 * std.time.ns_per_ms);
    const halfway = motions.place(moved, &clock).x;
    try std.testing.expect(halfway > 200 and halfway < 300);
    try std.testing.expectApproxEqAbs(halfway, motions.place(slot, &clock).x, 0.001);
    clock.begin(300 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f32, 0), motions.place(slot, &clock).x);
    try std.testing.expect(clock.deadline_ns == null);
    motions.begin(null);
    motions.finish();
    try std.testing.expectEqual(@as(usize, 0), motions.len);
}
