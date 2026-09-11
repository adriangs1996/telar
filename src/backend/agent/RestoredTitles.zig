const RestoredTitles = @This();
const source_namespace = @import("restored_titles.zig");
const types = @import("types.zig");
const Entry = struct {
    key: source_namespace.PaneKey,
    title: source_namespace.SessionTitle,
};

slots: [types.max_records]?Entry = .{null} ** types.max_records,

/// Stores one title for a pane generation, replacing an earlier one for the
/// same generation. Returns `false` when every slot is taken.
///
/// ```zig
/// _ = titles.put(pane.key(), title);
/// ```
pub fn put(titles: *RestoredTitles, key: source_namespace.PaneKey, title: source_namespace.SessionTitle) bool {
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
pub fn take(titles: *RestoredTitles, key: source_namespace.PaneKey) ?source_namespace.SessionTitle {
    const index = titles.indexOf(key) orelse return null;
    const title = titles.slots[index].?.title;
    titles.slots[index] = null;
    return title;
}

fn indexOf(titles: *const RestoredTitles, key: source_namespace.PaneKey) ?usize {
    for (titles.slots, 0..) |slot, index| {
        const entry = slot orelse continue;

        if (entry.key.id == key.id and entry.key.generation == key.generation) {
            return index;
        }
    }

    return null;
}
