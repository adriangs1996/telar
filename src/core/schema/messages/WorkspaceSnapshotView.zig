const id = @import("../id.zig");
const types = @import("../types.zig");
const TabDescriptorIterator = @import("TabDescriptorIterator.zig");
const WorkspaceSnapshotView = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
name: []const u8,
tab_count: u16,
encoded_tabs: []const u8,

pub fn tabs(snapshot: WorkspaceSnapshotView) TabDescriptorIterator {
    return .{
        .decoder = .init(snapshot.encoded_tabs),
        .remaining = snapshot.tab_count,
    };
}
