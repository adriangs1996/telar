const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const RestoredAgent = @import("RestoredAgent.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
const SessionTitleType = @import("SessionTitle.zig");
const ResumeSession = @import("ResumeSession.zig");
const RestoredAgents = @This();

slots: [max_agent_snapshot_entries]?RestoredAgent = .{null} ** max_agent_snapshot_entries,

/// Stores one title for a pane generation, replacing an earlier one for the
/// same generation. Returns `false` when every slot is taken.
///
/// ```zig
/// _ = restored.putTitle(pane.key(), title);
/// ```
pub fn putTitle(restored: *RestoredAgents, key: PaneKeyType, title: SessionTitleType) bool {
    const entry = restored.ensure(key) orelse return false;
    entry.title = title;
    return true;
}

/// Keeps the intended resume durable until the actual process is observed.
/// Example: `_ = restored.putSession(key, session);`.
pub fn putSession(restored: *RestoredAgents, key: PaneKeyType, session: ResumeSession) bool {
    const entry = restored.ensure(key) orelse return false;
    entry.session = session;
    return true;
}

/// Reads pending metadata without making it live agent evidence.
/// Example: `const pending = restored.get(key) orelse return;`.
pub fn get(restored: *const RestoredAgents, key: PaneKeyType) ?RestoredAgent {
    const index = restored.indexOf(key) orelse return null;
    return restored.slots[index];
}

/// Rejects a second automatic resume of the same provider session.
/// Example: `if (restored.containsSession(session)) return;`.
pub fn containsSession(restored: *const RestoredAgents, session: ResumeSession) bool {
    for (restored.slots) |slot| {
        const entry = slot orelse continue;
        const pending = entry.session orelse continue;
        if (pending.eql(session)) {
            return true;
        }
    }

    return false;
}

fn ensure(restored: *RestoredAgents, key: PaneKeyType) ?*RestoredAgent {
    if (restored.indexOf(key)) |index| {
        return &restored.slots[index].?;
    }

    for (&restored.slots) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = .{ .key = key };
        return &slot.*.?;
    }

    return null;
}

/// Removes and returns the metadata waiting for one pane generation.
///
/// ```zig
/// _ = restored.take(identity.key);
/// ```
pub fn take(restored: *RestoredAgents, key: PaneKeyType) ?RestoredAgent {
    const index = restored.indexOf(key) orelse return null;
    const entry = restored.slots[index];
    restored.slots[index] = null;
    return entry;
}

fn indexOf(restored: *const RestoredAgents, key: PaneKeyType) ?usize {
    for (restored.slots, 0..) |slot, index| {
        const entry = slot orelse continue;

        if (entry.key.id == key.id and entry.key.generation == key.generation) {
            return index;
        }
    }

    return null;
}
