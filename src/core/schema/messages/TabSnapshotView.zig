const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const PaneDescriptorIterator = @import("PaneDescriptorIterator.zig");
const TabSnapshotView = @This();

request_id: id.RequestId,
location: TabLocation,
pane_count: u16,
encoded_panes: []const u8,

pub fn panes(self: TabSnapshotView) PaneDescriptorIterator {
    return .{
        .decoder = .init(self.encoded_panes),
        .remaining = self.pane_count,
    };
}
