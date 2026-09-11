const ColorType = @import("telar-core").Color;
const sidebar = @import("sidebar.zig");
/// A bordered chip whose right edge is at `right`. Returns the columns it and
/// its trailing gap consumed.
const ChipDraw = @This();

right: u16,
label: []const u8,
color: ColorType,
action: sidebar.Action,
