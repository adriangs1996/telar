/// A bordered chip whose right edge is at `right`. Returns the columns it and
/// its trailing gap consumed.
const ChipDraw = @This();
const source_namespace = @import("sidebar.zig");
right: u16,
label: []const u8,
color: source_namespace.ui.Color,
action: source_namespace.Action,
