//! Allocation-free trajectories, bounded by visible pane attachments.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const Entry = @import("ThreadScrollMotion.zig");
const Clock = @import("../../animation/FrameClock.zig");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const Registry = @import("Registry.zig");
const Motions = @This();

entries: [core.max_panes_per_tab]Entry = undefined,
len: usize = 0,
gesture: ?Id = null,
gesture_pane: ?core.PaneId = null,
foreign_gesture: bool = false,
discarded_gesture: bool = false,

/// A replaced attachment never inherits its predecessor's velocity.
/// Example: `const entry = motions.obtain(pane, now_ns) orelse return;`
pub fn obtain(self: *Motions, pane: *const data.Pane, now_ns: u64) ?*Entry {
    const key: data.AgentKey = .{
        .pane_id = pane.id,
        .pane_generation = pane.attachment_generation,
    };
    if (self.find(key)) |entry| {
        entry.synchronize(pane, now_ns);
        return entry;
    }

    self.cancel(pane.id);
    if (self.len == self.entries.len) {
        return null;
    }

    const entry = &self.entries[self.len];
    self.len += 1;
    entry.* = .{ .key = key, .applied = pane.transcript_scroll, .anchor_revision = pane.transcript_anchor_revision };
    entry.motion.reset(pane.transcript_scroll * entry.step, now_ns);
    return entry;
}

/// Example: `const entry = motions.find(key) orelse return;`
pub fn find(self: *Motions, key: data.AgentKey) ?*Entry {
    for (self.entries[0..self.len]) |*entry| {
        if (std.meta.eql(entry.key, key)) {
            return entry;
        }
    }

    return null;
}

/// Stops at the current position when a reader grabs content or opens a group.
/// Example: `motions.cancel(pane_id);`
pub fn cancel(self: *Motions, pane_id: core.PaneId) void {
    if (self.gesture_pane == pane_id) {
        self.discarded_gesture = true;
    }

    for (self.entries[0..self.len], 0..) |entry, index| {
        if (entry.key.pane_id == pane_id) {
            self.len -= 1;
            self.entries[index] = self.entries[self.len];
            return;
        }
    }
}

/// Focus loss and modal ownership retire both animation and the native lease.
/// Example: `motions.clear();`
pub fn clear(self: *Motions) void {
    self.len = 0;
    self.gesture = null;
    self.gesture_pane = null;
    self.foreign_gesture = true;
    self.discarded_gesture = true;
}

/// Hidden, settled and replaced panes request no animation frames.
/// Example: `motions.schedule(target, clock);`
pub fn schedule(self: *Motions, target: Target, clock: *Clock) void {
    const entry = self.find(.{ .pane_id = target.action.transcript, .pane_generation = target.id.generation }) orelse return;
    const pending = @abs(entry.motion.spring.position - entry.applied * entry.step) > 0.001;
    if (!entry.waiting and (entry.motion.active() or pending)) {
        clock.requestAt(clock.now_ns +| Clock.frame_interval_ns);
    }
}

/// A failed frame cannot retire the previous visible set.
/// Example: `motions.retain(registry);`
pub fn retain(self: *Motions, registry: *const Registry) void {
    var kept: usize = 0;
    for (self.entries[0..self.len]) |entry| {
        for (registry.targets[0..registry.len]) |target| {
            if (target.action == .transcript and target.action.transcript == entry.key.pane_id and target.id.generation == entry.key.pane_generation) {
                self.entries[kept] = entry;
                kept += 1;
                break;
            }
        }
    }

    self.len = kept;
}
