const id = @import("../id.zig");
const types = @import("../types.zig");
const TabDescriptorIterator = @import("TabDescriptorIterator.zig");
const WorkspaceSnapshotView = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
name: []const u8,
tab_count: u16,
encoded_tabs: []const u8,

pub fn tabs(self: WorkspaceSnapshotView) TabDescriptorIterator {
    return .{
        .decoder = .init(self.encoded_tabs),
        .remaining = self.tab_count,
    };
}
