//! Bounded, disposable navigation bookmarks for workspace handoffs.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Bookmark = struct {
    location: schema.TabLocation,
    pane_id: schema.PaneId,
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
        if (free) |slot| slot.* = bookmark;
    }

    pub fn find(
        history: *const History,
        workspace: schema.WorkspaceLocation,
    ) ?Bookmark {
        for (history.entries) |slot| {
            const entry = slot orelse continue;
            if (std.meta.eql(entry.location.workspace, workspace)) return entry;
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
