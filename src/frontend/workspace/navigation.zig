//! Bounded, disposable navigation bookmarks for workspace handoffs.

const std = @import("std");
const core = @import("telar-core");
const layout_mod = @import("layout.zig");

const schema = core.schema;

pub const Bookmark = struct {
    location: schema.TabLocation,
    pane_id: schema.PaneId,
    tab_layout: ?layout_mod.Layout = null,
};

pub const SavedLayout = struct {
    location: schema.TabLocation,
    pane_id: schema.PaneId,
    workspace_active: bool,
    layout: layout_mod.Layout,
};

pub const Layouts = struct {
    entries: [schema.max_client_layout_tabs]?SavedLayout = @splat(null),

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

    /// Finds a retained tab layout without changing its lifetime.
    ///
    /// ```zig
    /// const saved = layouts.find(location) orelse return;
    /// ```
    pub fn find(layouts: *const Layouts, location: schema.TabLocation) ?SavedLayout {
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
    pub fn forget(layouts: *Layouts, location: schema.TabLocation) void {
        for (&layouts.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (std.meta.eql(entry.location, location)) {
                slot.* = null;
                return;
            }
        }
    }
};

pub const History = struct {
    entries: [schema.max_workspace_list_entries]?Bookmark = @splat(null),

    pub fn remember(history: *History, bookmark: Bookmark) void {
        var free: ?*?Bookmark = null;
        for (&history.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.meta.eql(entry.location.workspace, bookmark.location.workspace)) {
                    slot.* = bookmark;
                    return;
                }
            } else if (free == null) {
                free = slot;
            }
        }
        if (free) |slot| {
            slot.* = bookmark;
        }
    }

    pub fn find(history: *const History, workspace: schema.WorkspaceLocation) ?Bookmark {
        for (history.entries) |slot| {
            const entry = slot orelse continue;
            if (std.meta.eql(entry.location.workspace, workspace)) {
                return entry;
            }
        }
        return null;
    }

    pub fn forget(history: *History, workspace: schema.WorkspaceLocation) void {
        for (&history.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (std.meta.eql(entry.location.workspace, workspace)) {
                slot.* = null;
                return;
            }
        }
    }
};

test "workspace bookmarks replace the last focused tab and pane" {
    var history: History = .{};
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(3) };
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(4) },
        .pane_id = @enumFromInt(5),
    });
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(7) },
        .pane_id = @enumFromInt(9),
    });

    const restored = history.find(workspace).?;
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(7)), restored.location.tab_id);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(9)), restored.pane_id);
    history.forget(workspace);
    try std.testing.expect(history.find(workspace) == null);
}

test "saved layouts are keyed by complete tab identity" {
    var layouts: Layouts = .{};
    var first: layout_mod.Layout = .{};
    try first.addRoot(@enumFromInt(5));
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    try layouts.remember(.{
        .location = location,
        .pane_id = @enumFromInt(5),
        .workspace_active = true,
        .layout = first,
    });

    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(5)), layouts.find(location).?.pane_id);
    layouts.forget(location);
    try std.testing.expect(layouts.find(location) == null);
}
