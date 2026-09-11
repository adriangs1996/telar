const Layouts = @This();
const source_namespace = @import("navigation.zig");
const SavedLayout = @import("SavedLayout.zig");
const std = @import("std");
entries: [source_namespace.schema.max_client_layout_tabs]?SavedLayout = @splat(null),
eviction_index: usize = 0,

/// Retains the latest split tree for one stable tab identity.
///
/// ```zig
/// try layouts.remember(saved);
/// ```
pub fn remember(layouts: *Layouts, saved: SavedLayout) !void {
    var free: ?*?SavedLayout = null;
    for (&layouts.entries) |*slot| {
        if (slot.*) |entry| {
            if (std.meta.eql(entry.location, saved.location)) {
                slot.* = saved;
                return;
            }
        } else if (free == null) {
            free = slot;
        }
    }

    const slot = free orelse return error.TooManySavedLayouts;
    slot.* = saved;
}

/// Retains a live layout without blocking navigation when the cache fills.
/// Existing tabs replace their entry; overflow replaces slots round-robin.
/// Evicted layouts fall back to canonical pane order on their next visit.
///
/// ```zig
/// layouts.retain(saved);
/// ```
pub fn retain(layouts: *Layouts, saved: SavedLayout) void {
    layouts.remember(saved) catch {
        layouts.entries[layouts.eviction_index] = saved;
        layouts.eviction_index = (layouts.eviction_index + 1) % layouts.entries.len;
    };
}

/// Finds a retained tab layout without changing its lifetime.
///
/// ```zig
/// const saved = layouts.find(location) orelse return;
/// ```
pub fn find(layouts: *const Layouts, location: source_namespace.schema.TabLocation) ?SavedLayout {
    for (layouts.entries) |slot| {
        const entry = slot orelse continue;
        if (std.meta.eql(entry.location, location)) {
            return entry;
        }
    }

    return null;
}

/// Removes one layout after canonical pane reconciliation consumes it.
///
/// ```zig
/// layouts.forget(location);
/// ```
pub fn forget(layouts: *Layouts, location: source_namespace.schema.TabLocation) void {
    for (&layouts.entries) |*slot| {
        const entry = slot.* orelse continue;
        if (std.meta.eql(entry.location, location)) {
            slot.* = null;
            return;
        }
    }
}
