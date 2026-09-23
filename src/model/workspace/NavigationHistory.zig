const core = @import("telar-core");
const Bookmark = @import("Bookmark.zig");
const std = @import("std");
const History = @This();

entries: [core.max_workspace_list_entries]?Bookmark = @splat(null),

pub fn remember(self: *History, bookmark: Bookmark) void {
    var free: ?*?Bookmark = null;
    for (&self.entries) |*slot| {
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

pub fn find(self: *const History, workspace: core.WorkspaceLocation) ?Bookmark {
    for (self.entries) |slot| {
        const entry = slot orelse continue;
        if (std.meta.eql(entry.location.workspace, workspace)) {
            return entry;
        }
    }
    return null;
}

pub fn forget(self: *History, workspace: core.WorkspaceLocation) void {
    for (&self.entries) |*slot| {
        const entry = slot.* orelse continue;
        if (std.meta.eql(entry.location.workspace, workspace)) {
            slot.* = null;
            return;
        }
    }
}
