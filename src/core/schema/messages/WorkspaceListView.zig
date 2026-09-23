const WorkspaceListIterator = @import("WorkspaceListIterator.zig");
const WorkspaceListView = @This();

revision: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(self: WorkspaceListView) WorkspaceListIterator {
    return .{
        .decoder = .init(self.encoded_entries),
        .remaining = self.entry_count,
    };
}
