//! Panes whose graphics stream paused at a limit, each with its own resync
//! budget: how many graphics snapshots it asked for since `since_ns`, and
//! whether it waits for that window to pass before it asks again. A pane
//! past its budget never spends the link's.
const std = @import("std");
const core = @import("telar-core");
const GraphicsPauses = @This();

/// Paused panes one client tracks; a new one past this replaces the one
/// paused longest ago.
pub const capacity = core.max_panes_per_tab;

pane_id: [capacity]core.PaneId = undefined,
resyncs: [capacity]u8 = undefined,
since_ns: [capacity]u64 = undefined,
waiting: [capacity]bool = undefined,
count: usize = 0,
/// Rows waiting for their window to pass; zero keeps the per-message check
/// to one comparison.
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

/// Adds a row for a pane `find` did not find, replacing the oldest when
/// the table is full.
/// Example: `const slot = pauses.find(pane_id) orelse pauses.add(pane_id, now_ns);`
pub fn add(self: *GraphicsPauses, pane_id: core.PaneId, now_ns: u64) usize {
    var slot = self.count;
    if (self.count < capacity) {
        self.count += 1;
    } else {
        slot = 0;
        for (1..self.count) |candidate| {
            if (self.since_ns[candidate] < self.since_ns[slot]) {
                slot = candidate;
            }
        }

        self.setWaiting(slot, false);
    }

    self.pane_id[slot] = pane_id;
    self.resyncs[slot] = 0;
    self.since_ns[slot] = now_ns;
    self.waiting[slot] = false;
    return slot;
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

test "a full table replaces the pane paused longest ago" {
    var pauses: GraphicsPauses = .{};
    for (0..capacity) |number| {
        const slot = pauses.add(@enumFromInt(number + 1), number + 10);
        pauses.setWaiting(slot, true);
    }

    const slot = pauses.add(@enumFromInt(1000), 1_000);
    try std.testing.expectEqual(@as(usize, capacity), pauses.count);
    try std.testing.expectEqual(slot, pauses.find(@enumFromInt(1000)).?);
    try std.testing.expectEqual(@as(?usize, null), pauses.find(@enumFromInt(1)));
    try std.testing.expectEqual(@as(usize, capacity - 1), pauses.waiting_count);
}
