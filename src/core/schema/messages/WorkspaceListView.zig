const WorkspaceListView = @This();
const WorkspaceListIterator = @import("WorkspaceListIterator.zig");
revision: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(list: WorkspaceListView) WorkspaceListIterator {
    return .{
        .decoder = .init(list.encoded_entries),
        .remaining = list.entry_count,
    };
}
