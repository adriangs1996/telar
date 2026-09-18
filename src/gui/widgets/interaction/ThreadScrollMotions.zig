//! Allocation-free trajectories, bounded by visible pane attachments.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Entry = @import("ThreadScrollMotion.zig");
const Clock = @import("../../animation/FrameClock.zig");
const Target = @import("Target.zig");
const Motions = @This();

entries: [core.max_panes_per_tab]Entry = undefined,
len: usize = 0,
gesture: ?@import("Id.zig") = null,
gesture_pane: ?core.PaneId = null,
foreign_gesture: bool = false,
discarded_gesture: bool = false,

/// A replaced attachment never inherits its predecessor's velocity.
/// Example: `const entry = motions.obtain(pane, now_ns) orelse return;`
pub fn obtain(motions: *Motions, pane: *const client.Pane, now_ns: u64) ?*Entry {
    const key: client.AgentKey = .{ .pane_id = pane.id, .pane_generation = pane.attachment_generation };
    if (motions.find(key)) |entry| {
        entry.synchronize(pane, now_ns);
        return entry;
    }

    motions.cancel(pane.id);
    if (motions.len == motions.entries.len) {
        return null;
    }

    const entry = &motions.entries[motions.len];
    motions.len += 1;
    entry.* = .{ .key = key, .applied = pane.transcript_scroll, .anchor_revision = pane.transcript_anchor_revision };
    entry.motion.reset(pane.transcript_scroll * entry.step, now_ns);
    return entry;
}

/// Example: `const entry = motions.find(key) orelse return;`
pub fn find(motions: *Motions, key: client.AgentKey) ?*Entry {
    for (motions.entries[0..motions.len]) |*entry| {
        if (std.meta.eql(entry.key, key)) {
            return entry;
        }
    }

    return null;
}

/// Stops at the current position when a reader grabs content or opens a group.
/// Example: `motions.cancel(pane_id);`
pub fn cancel(motions: *Motions, pane_id: core.PaneId) void {
    if (motions.gesture_pane == pane_id) {
        motions.discarded_gesture = true;
    }

    for (motions.entries[0..motions.len], 0..) |entry, index| {
        if (entry.key.pane_id == pane_id) {
            motions.len -= 1;
            motions.entries[index] = motions.entries[motions.len];
            return;
        }
    }
}

/// Focus loss and modal ownership retire both animation and the native lease.
/// Example: `motions.clear();`
pub fn clear(motions: *Motions) void {
    motions.len = 0;
    motions.gesture = null;
    motions.gesture_pane = null;
    motions.foreign_gesture = true;
    motions.discarded_gesture = true;
}

/// Hidden, settled and replaced panes request no animation frames.
/// Example: `motions.schedule(target, clock);`
pub fn schedule(motions: *Motions, target: Target, clock: *Clock) void {
    const entry = motions.find(.{ .pane_id = target.action.transcript, .pane_generation = target.id.generation }) orelse return;
    const pending = @abs(entry.motion.spring.position - entry.applied * entry.step) > 0.001;
    if (!entry.waiting and (entry.motion.active() or pending)) {
        clock.requestAt(clock.now_ns +| Clock.frame_interval_ns);
    }
}

/// A failed frame cannot retire the previous visible set.
/// Example: `motions.retain(registry);`
pub fn retain(motions: *Motions, registry: *const @import("Registry.zig")) void {
    var kept: usize = 0;
    for (motions.entries[0..motions.len]) |entry| {
        for (registry.targets[0..registry.len]) |target| {
            if (target.action == .transcript and target.action.transcript == entry.key.pane_id and target.id.generation == entry.key.pane_generation) {
                motions.entries[kept] = entry;
                kept += 1;
                break;
            }
        }
    }

    motions.len = kept;
}
