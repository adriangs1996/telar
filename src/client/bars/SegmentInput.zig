const SegmentInput = @This();
const ui_icons = @import("../layout/root.zig").icons;
const Style = @import("Style.zig");
text: []const u8,
icon: ?ui_icons.Icon = null,
style: Style = .{},
