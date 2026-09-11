const WorkspaceSnapshotView = @This();
const source_namespace = @import("workspace.zig");
const TabDescriptorIterator = @import("TabDescriptorIterator.zig");
request_id: source_namespace.RequestId,
workspace: source_namespace.WorkspaceLocation,
name: []const u8,
tab_count: u16,
encoded_tabs: []const u8,

pub fn tabs(snapshot: WorkspaceSnapshotView) TabDescriptorIterator {
    return .{
        .decoder = .init(snapshot.encoded_tabs),
        .remaining = snapshot.tab_count,
    };
}
