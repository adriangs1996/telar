const max_workspace_list_entries_module = @import("telar-core").max_workspace_list_entries;
const Bookmark = @import("Bookmark.zig");
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const History = @This();

entries: [max_workspace_list_entries_module]?Bookmark = @splat(null),

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

pub fn find(history: *const History, workspace: WorkspaceLocationType) ?Bookmark {
    for (history.entries) |slot| {
        const entry = slot orelse continue;
        if (std.meta.eql(entry.location.workspace, workspace)) {
            return entry;
        }
    }
    return null;
}

pub fn forget(history: *History, workspace: WorkspaceLocationType) void {
    for (&history.entries) |*slot| {
        const entry = slot.* orelse continue;
        if (std.meta.eql(entry.location.workspace, workspace)) {
            slot.* = null;
            return;
        }
    }
}
