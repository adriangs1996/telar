const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const Entry = @import("Entry.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
const SessionTitleType = @import("SessionTitle.zig");
const RestoredTitles = @This();

slots: [max_agent_snapshot_entries]?Entry = .{null} ** max_agent_snapshot_entries,

/// Stores one title for a pane generation, replacing an earlier one for the
/// same generation. Returns `false` when every slot is taken.
///
/// ```zig
/// _ = titles.put(pane.key(), title);
/// ```
pub fn put(titles: *RestoredTitles, key: PaneKeyType, title: SessionTitleType) bool {
    if (titles.indexOf(key)) |index| {
        titles.slots[index].?.title = title;
        return true;
    }

    for (&titles.slots) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = .{ .key = key, .title = title };
        return true;
    }

    return false;
}

/// Removes and returns the title waiting for one pane generation.
///
/// ```zig
/// if (titles.take(identity.key)) |title| agent.restoreTitle(title);
/// ```
pub fn take(titles: *RestoredTitles, key: PaneKeyType) ?SessionTitleType {
    const index = titles.indexOf(key) orelse return null;
    const title = titles.slots[index].?.title;
    titles.slots[index] = null;
    return title;
}

fn indexOf(titles: *const RestoredTitles, key: PaneKeyType) ?usize {
    for (titles.slots, 0..) |slot, index| {
        const entry = slot orelse continue;

        if (entry.key.id == key.id and entry.key.generation == key.generation) {
            return index;
        }
    }

    return null;
}
