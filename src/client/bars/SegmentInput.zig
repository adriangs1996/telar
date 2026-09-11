const ui_icons = @import("../layout/icons.zig");
const Style = @import("Style.zig");
const SegmentInput = @This();

text: []const u8,
icon: ?ui_icons.Icon = null,
style: Style = .{},
