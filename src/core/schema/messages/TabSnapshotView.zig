const TabSnapshotView = @This();
const source_namespace = @import("tab.zig");
const PaneDescriptorIterator = @import("PaneDescriptorIterator.zig");
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
pane_count: u16,
encoded_panes: []const u8,

pub fn panes(snapshot: TabSnapshotView) PaneDescriptorIterator {
    return .{
        .decoder = .init(snapshot.encoded_panes),
        .remaining = snapshot.pane_count,
    };
}
