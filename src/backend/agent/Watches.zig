const Watches = @This();
const types = @import("types.zig");
const Watch = @import("Watch.zig");
const Registration = @import("Registration.zig");
const source_namespace = @import("session_file.zig");
const std = @import("std");
slots: [types.max_records]?Watch = @splat(null),

/// Registers or refreshes the session file of one pane generation. A
/// changed path, kind or session restarts the watch; the same ones keep
/// their progress. Returns `false` when every slot is taken or the path
/// exceeds the bound.
///
/// ```zig
/// _ = watches.put(.{ .key = pane.key(), .session = reference, .kind = .claude_transcript, .path = path });
/// ```
pub fn put(watches: *Watches, registration: Registration) bool {
    const path = registration.path;
    if (path.len == 0 or path.len > source_namespace.max_path_bytes) {
        return false;
    }

    if (watches.find(registration.key)) |watch| {
        if (watch.kind == registration.kind and std.mem.eql(u8, watch.pathSlice(), path) and
            std.mem.eql(u8, watch.session.slice(), registration.session.slice()))
        {
            return true;
        }

        watch.* = source_namespace.fresh(registration);
        return true;
    }

    for (&watches.slots) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = source_namespace.fresh(registration);
        return true;
    }

    return false;
}

pub fn find(watches: *Watches, key: source_namespace.PaneKey) ?*Watch {
    for (&watches.slots) |*slot| {
        if (slot.*) |*watch| {
            if (watch.key.id == key.id and watch.key.generation == key.generation) {
                return watch;
            }
        }
    }

    return null;
}

pub fn remove(watches: *Watches, key: source_namespace.PaneKey) bool {
    for (&watches.slots) |*slot| {
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
pub fn stalest(watches: *Watches, now_ms: i64, interval_ms: i64) ?*Watch {
    var chosen: ?*Watch = null;
    for (&watches.slots) |*slot| {
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

pub fn count(watches: *const Watches) usize {
    var total: usize = 0;
    for (&watches.slots) |slot| {
        if (slot != null) {
            total += 1;
        }
    }

    return total;
}
