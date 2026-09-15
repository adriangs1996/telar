const id = @import("id.zig");
const PaneForeground = @import("messages/PaneForeground.zig");
const TabDescriptor = @This();

tab_id: id.TabId,
position: u16,
pane_count: u16,
/// Empty means automatic; non-empty labels are explicit and survive foreground changes.
label: []const u8,
/// Metadata remains available before this client attaches the tab's panes.
foregrounds: []const PaneForeground = &.{},
