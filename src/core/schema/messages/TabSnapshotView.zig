const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const PaneDescriptorIterator = @import("PaneDescriptorIterator.zig");
const TabSnapshotView = @This();

request_id: id.RequestId,
location: TabLocationType,
pane_count: u16,
encoded_panes: []const u8,

pub fn panes(snapshot: TabSnapshotView) PaneDescriptorIterator {
    return .{
        .decoder = .init(snapshot.encoded_panes),
        .remaining = snapshot.pane_count,
    };
}
