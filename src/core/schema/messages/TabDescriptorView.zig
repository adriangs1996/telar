const id = @import("../id.zig");
const PaneForegroundIterator = @import("PaneForegroundIterator.zig");
const TabDescriptorView = @This();

tab_id: id.TabId,
position: u16,
pane_count: u16,
label: []const u8,
foreground_count: u16,
encoded_foregrounds: []const u8,

/// Iterates borrowed pane names without allocating or attaching terminals.
/// Example: `var names = descriptor.foregrounds();`.
pub fn foregrounds(self: TabDescriptorView) PaneForegroundIterator {
    return .{ .decoder = .init(self.encoded_foregrounds), .remaining = self.foreground_count };
}
