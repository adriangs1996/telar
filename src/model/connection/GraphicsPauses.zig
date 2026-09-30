//! Panes whose graphics stream paused at a limit, each with its own resync
//! budget: how many graphics snapshots it asked for since `since_ns`, and
//! whether it waits until `due_ns` before it asks again. Each window that
//! ends waiting counts in `backoff`, so a pane whose limit stays full waits
//! longer every time. A pane past its budget never spends the link's. A row
//! lives while its pane is paused: a snapshot that applies without pausing
//! again, the pane leaving the model or a new session removes it.
const std = @import("std");
const core = @import("telar-core");
const GraphicsPauses = @This();

/// Paused panes one client tracks: one row per pane the client mirrors, so
/// a table holding only live panes never fills.
pub const capacity = core.max_panes_per_tab;

pane_id: [capacity]core.PaneId = undefined,
resyncs: [capacity]u8 = undefined,
since_ns: [capacity]u64 = undefined,
/// When a waiting row asks again; meaningful only while `waiting`.
due_ns: [capacity]u64 = undefined,
/// Consecutive windows of this pause that ended waiting.
backoff: [capacity]u8 = undefined,
waiting: [capacity]bool = undefined,
/// A graphics snapshot began since the pane last reached its limit; its
/// end, applied, ends the pause.
snapshot_begun: [capacity]bool = undefined,
count: usize = 0,
/// Rows waiting for their window to pass; zero keeps every check to one
/// comparison and schedules no timer.
waiting_count: usize = 0,

/// The row of a pane, if its graphics paused.
/// Example: `const slot = pauses.find(pane_id) orelse return;`
pub fn find(self: *const GraphicsPauses, pane_id: core.PaneId) ?usize {
    for (self.pane_id[0..self.count], 0..) |paused, slot| {
        if (paused == pane_id) {
            return slot;
        }
    }

    return null;
}

/// Whether a pane's images are paused at a limit; the window marks the
/// pane with it. One comparison while no pane is paused.
/// Example: `if (model.graphics_pauses.contains(pane.id)) try drawPausedMark(canvas);`
pub fn contains(self: *const GraphicsPauses, pane_id: core.PaneId) bool {
    return self.find(pane_id) != null;
}

/// Adds a row for a pane `find` did not find. The table must have room:
/// the caller removes a row first when it is full (`oldest`).
/// Example: `const slot = pauses.find(pane_id) orelse pauses.add(pane_id, now_ns);`
pub fn add(self: *GraphicsPauses, pane_id: core.PaneId, now_ns: u64) usize {
    std.debug.assert(self.count < capacity);
    std.debug.assert(self.find(pane_id) == null);

    const slot = self.count;
    self.count += 1;
    self.pane_id[slot] = pane_id;
    self.resyncs[slot] = 0;
    self.since_ns[slot] = now_ns;
    self.due_ns[slot] = now_ns;
    self.backoff[slot] = 0;
    self.waiting[slot] = false;
    self.snapshot_begun[slot] = false;
    return slot;
}

/// Removes one row, moving the last row into its slot.
/// Example: `pauses.remove(slot);`
pub fn remove(self: *GraphicsPauses, slot: usize) void {
    std.debug.assert(slot < self.count);

    self.setWaiting(slot, false);
    const last = self.count - 1;
    self.pane_id[slot] = self.pane_id[last];
    self.resyncs[slot] = self.resyncs[last];
    self.since_ns[slot] = self.since_ns[last];
    self.due_ns[slot] = self.due_ns[last];
    self.backoff[slot] = self.backoff[last];
    self.waiting[slot] = self.waiting[last];
    self.snapshot_begun[slot] = self.snapshot_begun[last];
    self.count = last;
}

/// The row whose window started longest ago, the one a full table gives
/// up first.
/// Example: `const evicted = pauses.oldest();`
pub fn oldest(self: *const GraphicsPauses) usize {
    std.debug.assert(self.count != 0);

    var slot: usize = 0;
    for (1..self.count) |candidate| {
        if (self.since_ns[candidate] < self.since_ns[slot]) {
            slot = candidate;
        }
    }

    return slot;
}

/// The earliest time a waiting row asks again, or null when none waits,
/// so an idle client schedules no timer.
/// Example: `const deadline_ns = pauses.nextDue();`
pub fn nextDue(self: *const GraphicsPauses) ?u64 {
    if (self.waiting_count == 0) {
        return null;
    }

    var earliest: u64 = std.math.maxInt(u64);
    for (0..self.count) |slot| {
        if (self.waiting[slot]) {
            earliest = @min(earliest, self.due_ns[slot]);
        }
    }

    return earliest;
}

/// Marks whether a row waits, keeping `waiting_count` in step.
/// Example: `pauses.setWaiting(slot, true);`
pub fn setWaiting(self: *GraphicsPauses, slot: usize, waiting: bool) void {
    if (self.waiting[slot] == waiting) {
        return;
    }

    self.waiting[slot] = waiting;
    if (waiting) {
        self.waiting_count += 1;
    } else {
        self.waiting_count -= 1;
    }
}

test "removing a row keeps the rest findable and the waiting count in step" {
    var pauses: GraphicsPauses = .{};
    for (0..3) |number| {
        const slot = pauses.add(@enumFromInt(number + 1), number + 10);
        pauses.setWaiting(slot, true);
        pauses.due_ns[slot] = 100 - number;
    }

    try std.testing.expectEqual(@as(?u64, 98), pauses.nextDue());
    pauses.remove(pauses.find(@enumFromInt(1)).?);
    try std.testing.expectEqual(@as(usize, 2), pauses.count);
    try std.testing.expectEqual(@as(usize, 2), pauses.waiting_count);
    try std.testing.expect(!pauses.contains(@enumFromInt(1)));
    try std.testing.expect(pauses.contains(@enumFromInt(2)));
    try std.testing.expect(pauses.contains(@enumFromInt(3)));
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(2)), pauses.pane_id[pauses.oldest()]);

    pauses.remove(0);
    pauses.remove(0);
    try std.testing.expectEqual(@as(usize, 0), pauses.waiting_count);
    try std.testing.expectEqual(@as(?u64, null), pauses.nextDue());
}
