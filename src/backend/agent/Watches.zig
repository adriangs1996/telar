const core = @import("telar-core");
const Watch = @import("Watch.zig");
const Registration = @import("Registration.zig");
const std = @import("std");
const session_file = @import("session_file.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Watches = @This();

/// Session files watched at once: one per agent the snapshot carries.
pub const capacity = core.max_agent_snapshot_entries;
pub const capacity_limit = core.Limit.declare("agents.session_watches", "session files", capacity);

slots: [capacity]?Watch = @splat(null),

/// Registers or refreshes the session file of one pane generation. A
/// changed path, kind or session restarts the watch; the same ones keep
/// their progress. Returns `false` when every slot is taken or the path
/// exceeds the bound.
///
/// ```zig
/// _ = watches.put(.{ .key = pane.key(), .session = reference, .kind = .claude_transcript, .path = path });
/// ```
pub fn put(self: *Watches, registration: Registration) bool {
    const path = registration.path;
    if (path.len == 0 or path.len > core.max_agent_session_file_bytes) {
        return false;
    }

    if (self.find(registration.key)) |watch| {
        if (watch.kind == registration.kind and std.mem.eql(u8, watch.pathSlice(), path) and
            std.mem.eql(u8, watch.session.slice(), registration.session.slice()))
        {
            return true;
        }

        watch.* = session_file.fresh(registration);
        return true;
    }

    for (&self.slots) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = session_file.fresh(registration);
        return true;
    }

    return false;
}

/// Whether every slot holds a watch, so a new session file finds none.
///
/// ```zig
/// if (!watches.put(registration) and watches.full()) report();
/// ```
pub fn full(self: *const Watches) bool {
    for (self.slots) |slot| {
        if (slot == null) {
            return false;
        }
    }

    return true;
}

pub fn find(self: *Watches, key: PaneKey) ?*Watch {
    for (&self.slots) |*slot| {
        if (slot.*) |*watch| {
            if (watch.key.id == key.id and watch.key.generation == key.generation) {
                return watch;
            }
        }
    }

    return null;
}

pub fn remove(self: *Watches, key: PaneKey) bool {
    for (&self.slots) |*slot| {
        if (slot.*) |watch| {
            if (watch.key.id == key.id and watch.key.generation == key.generation) {
                slot.* = null;
                return true;
            }
        }
    }

    return false;
}

/// The due watch whose last probe is the oldest, or null when none is
/// due. A pending watch is never returned twice.
///
/// ```zig
/// const watch = watches.stalest(now_ms, 1_000) orelse return;
/// ```
pub fn stalest(self: *Watches, now_ms: i64, interval_ms: i64) ?*Watch {
    var chosen: ?*Watch = null;
    for (&self.slots) |*slot| {
        const watch = if (slot.*) |*value| value else continue;
        if (watch.pending or now_ms - watch.checked_at_ms < interval_ms) {
            continue;
        }

        if (chosen == null or watch.checked_at_ms < chosen.?.checked_at_ms) {
            chosen = watch;
        }
    }

    return chosen;
}

pub fn count(self: *const Watches) usize {
    var total: usize = 0;
    for (&self.slots) |slot| {
        if (slot != null) {
            total += 1;
        }
    }

    return total;
}
